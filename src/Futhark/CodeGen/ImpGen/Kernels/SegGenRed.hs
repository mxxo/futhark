{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
-- | Our compilation strategy for 'SegGenRed' is based around avoiding
-- bin conflicts.  We do this by splitting the input into chunks, and
-- for each chunk computing a single subhistogram.  Then we combine
-- the subhistograms using an ordinary segmented reduction ('SegRed').
--
-- There are some branches around to efficiently handle the case where
-- we use only a single subhistogram (because it's large), so that we
-- respect the asymptotics, and do not copy the destination array.
module Futhark.CodeGen.ImpGen.Kernels.SegGenRed
  ( compileSegGenRed )
  where

import Control.Monad.Except
import Data.Maybe
import Data.List

import Prelude hiding (quot, rem)

import Futhark.MonadFreshNames
import Futhark.Representation.ExplicitMemory
import qualified Futhark.Representation.ExplicitMemory.IndexFunction as IxFun
import Futhark.Pass.ExplicitAllocations()
import qualified Futhark.CodeGen.ImpCode.Kernels as Imp
import qualified Futhark.CodeGen.ImpGen as ImpGen
import Futhark.CodeGen.ImpGen ((<--),
                               sFor, sComment, sIf, sWhen, sArray,
                               dPrim_, dPrimV)
import Futhark.CodeGen.ImpGen.Kernels.SegRed (compileSegRed')
import Futhark.CodeGen.ImpGen.Kernels.Base
import Futhark.Util.IntegralExp (quotRoundingUp, quot, rem)
import Futhark.Util (chunks, mapAccumLM, splitFromEnd, takeLast)
import Futhark.Construct (fullSliceNum)

import Debug.Trace

prepareAtomicUpdateGlobal :: Maybe Locking -> [VName] -> Lambda InKernel
                          -> CallKernelGen (Maybe Locking,
                                            [Imp.Exp] -> ImpGen.ImpM InKernel Imp.KernelOp ())
prepareAtomicUpdateGlobal l dests lam =
  -- We need a separate lock array if the opterators are not all of a
  -- particularly simple form that permits pure atomic operations.
  case (l, atomicUpdateLocking (Space "global") lam) of
    (_, Left f) -> return (l, f dests)
    (Just l', Right f) -> return (l, f l' dests)
    (Nothing, Right f) -> do
      -- The number of locks used here is too low, but since we are
      -- currently forced to inline a huge list, I'm keeping it down
      -- for now.  Some quick experiments suggested that it has little
      -- impact anyway (maybe the locking case is just too slow).
      --
      -- A fun solution would also be to use a simple hashing
      -- algorithm to ensure good distribution of locks.
      let num_locks = 10000
      locks <-
        ImpGen.sStaticArray "genred_locks" (Space "device") int32 $
        Imp.ArrayZeros num_locks
      let l' = Locking locks 0 1 0 ((`rem` fromIntegral num_locks) . sum)
      return (Just l', f l' dests)

prepareIntermediateArraysGlobal :: [SubExp] -> Imp.Exp -> [GenReduceOp InKernel]
                                -> CallKernelGen
                                   [(VName,
                                     [VName],
                                     [Imp.Exp] -> ImpGen.ImpM InKernel Imp.KernelOp ())]
prepareIntermediateArraysGlobal segment_dims num_threads = fmap snd . mapAccumLM onOp Nothing
  where
    onOp l op = do
      -- Determining the degree of cooperation (heuristic):
      -- coop_lvl   := size of histogram (Cooperation level)
      -- num_histos := (threads / coop_lvl) (Number of histograms)
      -- threads    := min(physical_threads, segment_size)
      --
      -- Careful to avoid division by zero when genReduceWidth==0.
      num_histos <- dPrimV "num_histos" $ num_threads `quotRoundingUp`
                    BinOpExp (SMax Int32) 1 (ImpGen.compileSubExpOfType int32 (genReduceWidth op))

      ImpGen.emit $ Imp.DebugPrint "num_histograms" int32 $ Imp.var num_histos int32

      -- Initialise sub-histograms.
      --
      -- If num_histos is 1, then we just reuse the original
      -- destination.  The idea is to avoid a copy if we are writing a
      -- small number of values into a very large prior histogram.

      dests <- forM (zip (genReduceDest op) (genReduceNeutral op)) $ \(dest, ne) -> do
        dest_t <- lookupType dest
        dest_mem <- ImpGen.entryArrayLocation <$> ImpGen.lookupArray dest
        let num_elems = foldl' (*) (Imp.var num_histos int32) $
                        map (ImpGen.compileSubExpOfType int32) $
                        arrayDims dest_t
        let size = Imp.elements num_elems `Imp.withElemType` int32

        (sub_mem, size') <-
          ImpGen.sDeclareMem "subhistogram_mem" size $ Space "device"

        let num_segments = length segment_dims
            sub_shape = Shape (segment_dims++[Var num_histos]) <>
                        stripDims num_segments (arrayShape dest_t)
            sub_membind = ArrayIn sub_mem $ IxFun.iota $
                          map (primExpFromSubExp int32) $ shapeDims sub_shape
        subhisto <- sArray "genred_dest" (elemType dest_t) sub_shape sub_membind

        let unitHistoCase =
              ImpGen.emit $
              Imp.SetMem sub_mem (ImpGen.memLocationName dest_mem) $
              Space "device"

            multiHistoCase = do
              ImpGen.sAlloc_ sub_mem size' $ Space "device"
              sReplicate subhisto (Shape $ segment_dims ++ [Var num_histos, genReduceWidth op]) ne
              subhisto_t <- lookupType subhisto
              let slice = fullSliceNum (map (ImpGen.compileSubExpOfType int32) $ arrayDims subhisto_t) $
                          map (unitSlice 0 . ImpGen.compileSubExpOfType int32) segment_dims ++
                          [DimFix 0]
              ImpGen.sUpdate subhisto slice $ Var dest

        sIf (Imp.var num_histos int32 .==. 1) unitHistoCase multiHistoCase

        return subhisto

      (l', do_op) <- prepareAtomicUpdateGlobal l dests $ genReduceOp op

      return (l', (num_histos, dests, do_op))

genRedKernelGlobal :: [PatElem ExplicitMemory]
                   -> KernelSpace
                   -> [GenReduceOp InKernel]
                   -> KernelBody InKernel
                   -> CallKernelGen [(VName, [VName])]
genRedKernelGlobal map_pes space ops kbody = do
  (base_constants, init_constants) <- kernelInitialisationSetSpace space $ return ()
  let constants = base_constants { kernelThreadActive = true }
      (space_is, space_sizes) = unzip $ spaceDimensions space
      i32_to_i64 = ConvOpExp (SExt Int32 Int64)
      space_sizes_64 = map (i32_to_i64 . ImpGen.compileSubExpOfType int32) space_sizes
      total_w_64 = product space_sizes_64

  histograms <- prepareIntermediateArraysGlobal (init space_sizes) (kernelNumThreads constants) ops

  elems_per_thread_64 <- dPrimV "elems_per_thread_64" $
                         total_w_64 `quotRoundingUp`
                         ConvOpExp (SExt Int32 Int64) (kernelNumThreads constants)

  sKernel constants "seggenred" $ allThreads constants $ do
    init_constants

    i <- newVName "i"

    -- Compute subhistogram index for each thread, per histogram.
    subhisto_inds <- forM histograms $ \(num_histograms, _, _) ->
      dPrimV "subhisto_ind" $
      kernelGlobalThreadId constants `quot`
      (kernelNumThreads constants `quotRoundingUp` Imp.var num_histograms int32)

    sFor i Int64 (Imp.var elems_per_thread_64 int64) $ do
      -- Compute the offset into the input and output.  To this a
      -- thread can add its local ID to figure out which element it is
      -- responsible for.  The calculation is done with 64-bit
      -- integers to avoid overflow, but the final segment indexes are
      -- 32 bit.
      offset <- dPrimV "offset" $
                (i32_to_i64 (kernelGroupId constants) *
                 (Imp.var elems_per_thread_64 int64 *
                  i32_to_i64 (kernelGroupSize constants)))
                + (Imp.var i int64 * i32_to_i64 (kernelGroupSize constants))

      j <- dPrimV "j" $ Imp.var offset int64 + i32_to_i64 (kernelLocalThreadId constants)

      -- Construct segment indices.
      let setIndex v e = do dPrim_ v int32
                            v <-- e
      zipWithM_ setIndex space_is $
        map (ConvOpExp (SExt Int64 Int32)) . unflattenIndex space_sizes_64 $ Imp.var j int64

      -- We execute the bucket function once and update each histogram serially.
      -- We apply the bucket function if j=offset+ltid is less than
      -- num_elements.  This also involves writing to the mapout
      -- arrays.
      let input_in_bounds = Imp.var j int32 .<. total_w_64

      sWhen input_in_bounds $ ImpGen.compileStms mempty (kernelBodyStms kbody) $ do
        let (red_res, map_res) = splitFromEnd (length map_pes) $ kernelBodyResult kbody

        sComment "save map-out results" $
          forM_ (zip map_pes map_res) $ \(pe, res) ->
          ImpGen.copyDWIM (patElemName pe)
          (map ((`Imp.var` int32) . fst) $ kernelDimensions constants)
          (kernelResultSubExp res) []

        let (buckets, vs) = splitAt (length ops) red_res
            perOp = chunks $ map (length . genReduceDest) ops

        sComment "perform atomic updates" $
          forM_ (zip5 ops histograms buckets (perOp vs) subhisto_inds) $
          \(GenReduceOp dest_w _ _ shape lam,
            (_, _, do_op), bucket, vs', subhisto_ind) -> do

            let bucket' = ImpGen.compileSubExpOfType int32 $ kernelResultSubExp bucket
                dest_w' = ImpGen.compileSubExpOfType int32 dest_w
                bucket_in_bounds = 0 .<=. bucket' .&&. bucket' .<. dest_w'
                bucket_is = map (`Imp.var` int32) (init space_is) ++
                            [Imp.var subhisto_ind int32, bucket']
                vs_params = takeLast (length vs') $ lambdaParams lam

            sWhen bucket_in_bounds $ do
              ImpGen.dLParams $ lambdaParams lam
              vectorLoops [] (shapeDims shape) $ \is -> do
                forM_ (zip vs_params vs') $ \(p, res) ->
                  ImpGen.copyDWIM (paramName p) [] (kernelResultSubExp res) is
                do_op (bucket_is ++ is)

  let histogramInfo (num_histos, dests, _) = (num_histos, dests)
  return $ map histogramInfo histograms

vectorLoops :: [Imp.Exp] -> [SubExp]
            -> ([Imp.Exp] -> ImpGen.ImpM lore op ())
            -> ImpGen.ImpM lore op ()
vectorLoops is [] f = f $ reverse is
vectorLoops is (d:ds) f = do
  i <- newVName "i"
  d' <- ImpGen.compileSubExp d
  ImpGen.sFor i Int32 d' $ vectorLoops (Imp.var i int32:is) ds f

compileSegGenRedGlobal :: Pattern ExplicitMemory
                       -> KernelSpace
                       -> [GenReduceOp InKernel]
                       -> KernelBody InKernel
                       -> CallKernelGen ()
compileSegGenRedGlobal (Pattern _ pes) genred_space ops body = do
  let num_red_res = length ops + sum (map (length . genReduceNeutral) ops)
      (all_red_pes, map_pes) = splitAt num_red_res pes

  infos <- genRedKernelGlobal map_pes genred_space ops body
  let pes_per_op = chunks (map (length . genReduceDest) ops) all_red_pes

  forM_ (zip3 infos pes_per_op ops) $ \((num_histos, subhistos), red_pes, op) -> do
    let unitHistoCase =
          -- This is OK because the memory blocks are at least as
          -- large as the ones we are supposed to use for the result.
          forM_ (zip red_pes subhistos) $ \(pe, subhisto) -> do
            pe_mem <- ImpGen.memLocationName . ImpGen.entryArrayLocation <$>
                      ImpGen.lookupArray (patElemName pe)
            subhisto_mem <- ImpGen.memLocationName . ImpGen.entryArrayLocation <$>
                            ImpGen.lookupArray subhisto
            ImpGen.emit $ Imp.SetMem pe_mem subhisto_mem $ Space "device"

    sIf (Imp.var num_histos int32 .==. 1) unitHistoCase $ do
      -- For the segmented reduction, we keep the segment dimensions
      -- unchanged.  To this, we add two dimensions: one over the number
      -- of buckets, and one over the number of subhistograms.  This
      -- inner dimension is the one that is collapsed in the reduction.
      let segment_dims = init $ spaceDimensions genred_space
          num_buckets = genReduceWidth op

      bucket_id <- newVName "bucket_id"
      subhistogram_id <- newVName "subhistogram_id"
      vector_ids <- mapM (const $ newVName "vector_id") $
                    shapeDims $ genReduceShape op
      gtid <- newVName $ baseString $ spaceGlobalId genred_space
      let lam = genReduceOp op
          segred_space =
            genred_space
            { spaceStructure =
                FlatThreadSpace $
                segment_dims ++
                [(bucket_id, num_buckets)] ++
                zip vector_ids (shapeDims $ genReduceShape op) ++
                [(subhistogram_id, Var num_histos)]
            , spaceGlobalId = gtid
            }

      compileSegRed' (Pattern [] red_pes) segred_space
        Commutative lam (genReduceNeutral op) $ \_ red_dests ->
        forM_ (zip red_dests subhistos) $ \((d, is), subhisto) ->
          ImpGen.copyDWIM d is (Var subhisto) $ map (`Imp.var` int32) $
          map fst segment_dims ++ [subhistogram_id, bucket_id] ++ vector_ids

prepareAtomicUpdateLocal :: SubExp -> Maybe Locking -> [VName] -> Lambda InKernel
                         -> CallKernelGen (Maybe Locking,
                                           [Imp.Exp] -> ImpGen.ImpM InKernel Imp.KernelOp ())
prepareAtomicUpdateLocal num_locks l dests lam =
  -- We need a separate lock array if the opterators are not all of a
  -- particularly simple form that permits pure atomic operations.
  case (l, atomicUpdateLocking (Space "local") lam) of
    (_, Left f) -> return (l, f dests)
    (Just l', Right f) -> return (l, f l' dests)
    (Nothing, Right f) -> do
      locks <- ImpGen.sAllocArray "genred_locks" int32 (Shape [num_locks]) $ Space "local"
      num_locks' <- ImpGen.compileSubExp num_locks
      let l' = Locking locks 0 1 0 $ (`rem` num_locks') . sum
      return (Just l', f l' dests)

-- XXX: Reuse code.
prepareIntermediateArraysLocal :: KernelSpace -> [SubExp] -> Imp.Exp -> Imp.Exp -> [GenReduceOp InKernel]
                               -> CallKernelGen
                                  [(VName,
                                    [(VName, VName)],
                                    [Imp.Exp] -> ImpGen.ImpM InKernel Imp.KernelOp (),
                                    (VName, VName))]
prepareIntermediateArraysLocal space segment_dims num_threads num_groups = fmap snd . mapAccumLM onOp Nothing
  where
    onOp l op = do
      -- Determining the degree of cooperation (heuristic):
      --
      -- number of bytes of local memory per thread :=
      --   amount of local memory per group / number of threads in a group
      --
      -- coop_lvl :=
      --   number of entries in histogram
      --   / number of bytes of local memory per thread / sizeof(element type)
      --
      -- coop_lvl' :=
      --   round coop_lvl up to the nearest power of two (easy way to ensure
      --   full occupancy in the group, at the cost of not using all of the
      --   available local memory -- maybe we can do this better)
      --
      -- num_threads := min(physical_threads, segment_size)
      --
      -- num_histos_per_group := (num_threads / coop_lvl')
      --
      -- num_histos := num_histos_per_group * number of groups

      let local_mem_per_group = ImpGen.compilePrimExp (12 * 1024) -- XXX: Query the device.
          elem_size = Imp.LeafExp (Imp.SizeOf int32) int32 -- XXX: Use dest_t.
          hist_size = ImpGen.compileSubExpOfType int32 $ genReduceWidth op
          coop_lvl = BinOpExp (SMax Int32) 1 -- XXX: pow2
                     (hist_size `quotRoundingUp`
                      (BinOpExp (SMax Int32) 1 (local_mem_per_group `quot` elem_size `quot` ImpGen.compileSubExpOfType int32 (spaceGroupSize space))))
          num_hists_per_group = BinOpExp (SMin Int32)
                                (local_mem_per_group `quot` (BinOpExp (SMax Int32) 1 hist_size))
                                (ImpGen.compileSubExpOfType int32 (spaceGroupSize space) `quot` coop_lvl)
          group_hists_size = num_hists_per_group * hist_size
          num_hists = num_hists_per_group * num_groups

      coop_lvl' <- dPrimV "coop_lvl" coop_lvl
      group_hists_size' <- dPrimV "group_hists_size" group_hists_size
      num_hists' <- dPrimV "num_hists" num_hists
      num_hists_inc1 <- dPrimV "num_hists_inc1" $ Imp.var num_hists' int32 + 1

      forM_ [ ("Number of threads", num_threads)
            , ("Element size", elem_size)
            , ("Histogram size", hist_size)
            , ("Cooperation level", coop_lvl)
            , ("Group hists size", group_hists_size)
            , ("Number of histograms per group", num_hists_per_group)
            , ("Number of histograms", num_hists)
            ]
        $ \(v, e) -> ImpGen.emit $ Imp.DebugPrint v int32 e

      -- Initialise sub-histograms.
      dests <- forM (zip (genReduceDest op) (genReduceNeutral op)) $ \(dest, ne) -> do
        dest_t <- lookupType dest
        let num_elems = foldl' (*) (Imp.var num_hists_inc1 int32) $
                        map (ImpGen.compileSubExpOfType int32) $
                        arrayDims dest_t
        let size = Imp.elements num_elems `Imp.withElemType` int32

        (sub_mem, size') <-
          ImpGen.sDeclareMem "subhistogram_mem" size $ Space "device"

        let sub_local_shape = Shape [intConst Int32 (16 * 256)] -- XXX
        subhistogram_local <- ImpGen.sAllocArray "subhistogram_local" (elemType dest_t) sub_local_shape $ Space "local"

        let num_segments = length segment_dims
            sub_shape = Shape (segment_dims++[Var num_hists_inc1]) <>
                        stripDims num_segments (arrayShape dest_t)
            sub_membind = ArrayIn sub_mem $ IxFun.iota $
                          map (primExpFromSubExp int32) $ shapeDims sub_shape
        subhisto <- sArray "genred_dest" (elemType dest_t) sub_shape sub_membind

        ImpGen.sAlloc_ sub_mem size' $ Space "device"
        sReplicate subhisto (Shape $ segment_dims ++ [Var num_hists', genReduceWidth op]) ne
        subhisto_t <- lookupType subhisto
        -- Allocate one more global subhistogram than needed for the in-kernel
        -- transfer from local to global memory, and then put the histogram
        -- memory inside just that one.  This subhistogram is then also used in
        -- the final reduction phase.  This approach ensures that the original
        -- contents of the input histogram are not ignored, but is also a bit
        -- more wasteful than the global-memory-only approach.  This seems the
        -- simplest way to do it.
        let slice = fullSliceNum (map (ImpGen.compileSubExpOfType int32) $ arrayDims subhisto_t) $
                    map (unitSlice 0 . ImpGen.compileSubExpOfType int32) segment_dims ++
                    [DimFix (Imp.var num_hists' int32)]
        ImpGen.sUpdate subhisto slice $ Var dest

        return (subhisto, subhistogram_local)

      (l', do_op) <- prepareAtomicUpdateLocal (genReduceWidth op)
                     l (map snd dests) $ genReduceOp op

      return (l', (num_hists', dests, do_op, (coop_lvl', group_hists_size')))

genRedKernelLocal :: [PatElem ExplicitMemory]
                  -> KernelSpace
                  -> [GenReduceOp InKernel]
                  -> KernelBody InKernel
                  -> CallKernelGen [(VName, [VName])]
genRedKernelLocal map_pes space ops kbody = do
  (base_constants, init_constants) <- kernelInitialisationSetSpace space $ return ()
  let constants0 = base_constants { kernelThreadActive = true }
      (space_is, space_sizes) = unzip $ spaceDimensions space
      i32_to_i64 = ConvOpExp (SExt Int32 Int64)
      space_sizes_64 = map (i32_to_i64 . ImpGen.compileSubExpOfType int32) space_sizes
      total_w_64 = product space_sizes_64
      segment_dims = init space_sizes
      img_size = kernelNumThreads constants0

      -- Chunk to better exploit local memory.
      num_threads_hdw = BinOpExp (SMin Int32)
                        (ImpGen.compilePrimExp 69632) -- XXX: Query the device.
                        (kernelNumThreads constants0)
      constants = constants0 { kernelNumThreads = num_threads_hdw
                             , kernelNumGroups =
                                 num_threads_hdw `quotRoundingUp` kernelGroupSize constants
                             }

  histograms <- prepareIntermediateArraysLocal space segment_dims img_size
                (kernelNumGroups constants) ops

  elems_per_thread_64 <- dPrimV "elems_per_thread_64" $
                         total_w_64 `quotRoundingUp`
                         ConvOpExp (SExt Int32 Int64) (kernelNumThreads constants)
  ImpGen.emit $ Imp.DebugPrint "Elements per thread" int64 $ Imp.var elems_per_thread_64 int64

  sKernel constants "seggenred" $ allThreads constants $ do
    init_constants

    i <- newVName "i"

    -- Compute subhistogram index for each thread, per histogram.
    subhisto_local_inds <- forM (zip histograms ops) $ \((_, _, _, (coop_lvl, _)), op) ->
      dPrimV "subhisto_local_ind" $
      kernelLocalThreadId constants `quot`
      ((kernelNumThreads constants `quot` Imp.var coop_lvl int32)
       * ImpGen.compileSubExpOfType int32 (genReduceWidth op))

    subhisto_global_inds <- forM histograms $ \(_, _, _, (_, group_hists_size)) ->
      dPrimV "subhisto_global_ind" $
      kernelGroupId constants * Imp.var group_hists_size int32

    let (red_res, map_res) = splitFromEnd (length map_pes) $
                             map kernelResultSubExp $ kernelBodyResult kbody
        (buckets, vs) = splitAt (length ops) red_res
        perOp = chunks $ map (length . genReduceDest) ops

    -- XXX: support more than one dest with local memory?  quickly becomes inefficient
    forM_ (zip ops histograms) $
      \(GenReduceOp _ _ nes _ _,
        (_, dests, _, (_, group_hists_size))) ->
        sComment "initialize histograms in local memory" $
          forM_ (zip dests nes) $ \((_dest_global, dest_local), ne) -> do
          ne' <- ImpGen.compileSubExp ne
          i' <- newVName "i"
          sFor i' Int32 (Imp.var group_hists_size int32
                         `quot` kernelGroupSize constants) $ do
            let j' = Imp.var i' int32 * kernelGroupSize constants + kernelLocalThreadId constants
            ImpGen.sWrite dest_local [j'] ne'

    ImpGen.sOp Imp.LocalBarrier

    sFor i Int64 (Imp.var elems_per_thread_64 int64) $ do
      -- Compute the offset into the input and output.  To this a
      -- thread can add its local ID to figure out which element it is
      -- responsible for.  The calculation is done with 64-bit
      -- integers to avoid overflow, but the final segment indexes are
      -- 32 bit.
      offset <- dPrimV "offset" $
                (i32_to_i64 (kernelGroupId constants) *
                 (Imp.var elems_per_thread_64 int64 *
                  i32_to_i64 (kernelGroupSize constants)))
                + (Imp.var i int64 * i32_to_i64 (kernelGroupSize constants))

      j <- dPrimV "j" $ Imp.var offset int64 + i32_to_i64 (kernelLocalThreadId constants)

      -- Construct segment indices.
      let setIndex v e = do dPrim_ v int32
                            v <-- e
      zipWithM_ setIndex space_is $
        map (ConvOpExp (SExt Int64 Int32)) . unflattenIndex space_sizes_64 $ Imp.var j int64

      -- We execute the bucket function once and update each histogram serially.
      -- We apply the bucket function if j=offset+ltid is less than
      -- num_elements.  This also involves writing to the mapout
      -- arrays.
      let input_in_bounds = Imp.var j int32 .<. total_w_64

      sWhen input_in_bounds $ ImpGen.compileStms mempty (kernelBodyStms kbody) $ do

        sComment "save map-out results" $
          forM_ (zip map_pes map_res) $ \(pe, se) ->
          ImpGen.copyDWIM (patElemName pe)
          (map ((`Imp.var` int32) . fst) $ kernelDimensions constants) se []

        forM_ (zip5 ops histograms buckets (perOp vs) subhisto_local_inds) $
          \(GenReduceOp dest_w _ _ shape lam,
            (_, _, do_op, _), bucket, vs',
            subhisto_local_ind) -> do

            let bucket' = ImpGen.compileSubExpOfType int32 bucket
                dest_w' = ImpGen.compileSubExpOfType int32 dest_w
                bucket_in_bounds = 0 .<=. bucket' .&&. bucket' .<. dest_w'
                bucket_is = map (`Imp.var` int32) (init space_is) ++
                            [Imp.var subhisto_local_ind int32 + bucket', bucket']
                vs_params = takeLast (length vs') $ lambdaParams lam

            sComment "perform atomic updates" $
              sWhen bucket_in_bounds $ do
              ImpGen.dLParams vs_params
              vectorLoops [] (shapeDims shape) $ \is -> do
                forM_ (zip vs_params vs') $ \(p, v) ->
                  ImpGen.copyDWIM (paramName p) [] v is
                trace ("do_op " ++ show bucket_is ++ " " ++ show is) $ do_op (bucket_is ++ is)

    ImpGen.sOp Imp.LocalBarrier

    forM_ (zip4 histograms buckets (perOp vs) subhisto_global_inds) $
      \((_, dests, _, (_, group_hists_size)), _, _,
        subhisto_global_ind) ->
        sComment "copy local histogram to global memory" $
          forM_ dests $ \(dest_global, dest_local) -> do
          i' <- newVName "i"
          sFor i' Int32 (Imp.var group_hists_size int32
                         `quot` kernelGroupSize constants) $ do
            let j' = Imp.var i' int32 * kernelGroupSize constants + kernelLocalThreadId constants
                global_j = Imp.var subhisto_global_ind int32 + j'
            ImpGen.copyDWIM dest_global [0, global_j] (Var dest_local) [j']

  let histogramInfo (num_histos, dests, _, _) = (num_histos, map fst dests)
  return $ map histogramInfo histograms

compileSegGenRedLocal :: Pattern ExplicitMemory
                      -> KernelSpace
                      -> [GenReduceOp InKernel]
                      -> KernelBody InKernel
                      -> CallKernelGen ()
compileSegGenRedLocal (Pattern _ pes) space ops kbody = do
  let num_red_res = length ops + sum (map (length . genReduceNeutral) ops)
      (all_red_pes, map_pes) = splitAt num_red_res pes

  infos <- genRedKernelLocal map_pes space ops kbody
  let pes_per_op = chunks (map (length . genReduceDest) ops) all_red_pes

  forM_ (zip3 infos pes_per_op ops) $ \((num_histos, subhistos), red_pes, op) -> do
    -- For the segmented reduction, we keep the segment dimensions
    -- unchanged.  To this, we add two dimensions: one over the number
    -- of buckets, and one over the number of subhistograms.  This
    -- inner dimension is the one that is collapsed in the reduction.
    let segment_dims = init $ spaceDimensions space
        num_buckets = genReduceWidth op

    num_hists_inc1 <- dPrimV "num_hists_inc1" $ Imp.var num_histos int32 + 1

    bucket_id <- newVName "bucket_id"
    subhistogram_id <- newVName "subhistogram_id"
    vector_ids <- mapM (const $ newVName "vector_id") $
                  shapeDims $ genReduceShape op
    gtid <- newVName $ baseString $ spaceGlobalId space
    let lam = genReduceOp op
        segred_space =
          space
          { spaceStructure =
              FlatThreadSpace $
              segment_dims ++
              [(bucket_id, num_buckets)] ++
              zip vector_ids (shapeDims $ genReduceShape op) ++
              [(subhistogram_id, Var num_hists_inc1)]
          , spaceGlobalId = gtid
          }

    compileSegRed' (Pattern [] red_pes) segred_space
      Commutative lam (genReduceNeutral op) $ \_ red_dests ->
      forM_ (zip red_dests subhistos) $ \((d, is), subhisto) ->
        ImpGen.copyDWIM d is (Var subhisto) $ map (`Imp.var` int32) $
        map fst segment_dims ++ [subhistogram_id, bucket_id] ++ vector_ids

-- | Can we reliably use the kernel that computes subhistograms in local memory?
-- This can be determined at runtime.
fitsInLocalMemory :: KernelSpace -> [GenReduceOp InKernel] -> CallKernelGen ()
fitsInLocalMemory = undefined

compileSegGenRed :: Pattern ExplicitMemory
                 -> KernelSpace
                 -> [GenReduceOp InKernel]
                 -> KernelBody InKernel
                 -> CallKernelGen ()
-- compileSegGenRed = compileSegGenRedGlobal
compileSegGenRed = compileSegGenRedLocal
