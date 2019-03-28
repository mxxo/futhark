{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}
-- | This module defines a translation from imperative code with
-- kernels to imperative code with OpenCL calls.
module Futhark.CodeGen.ImpGen.Kernels.ToOpenCL
  ( kernelsToOpenCL
  , kernelsToCUDA
  )
  where

import Control.Monad.State
import Control.Monad.Identity
import Control.Monad.Writer
import Control.Monad.Reader
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Map.Strict as M

import qualified Language.C.Syntax as C
import qualified Language.C.Quote.OpenCL as C
import qualified Language.C.Quote.CUDA as CUDAC

import Futhark.Error
import qualified Futhark.CodeGen.Backends.GenericC as GenericC
import Futhark.CodeGen.Backends.SimpleRepresentation
import Futhark.CodeGen.ImpCode.Kernels hiding (Program)
import qualified Futhark.CodeGen.ImpCode.Kernels as ImpKernels
import Futhark.CodeGen.ImpCode.OpenCL hiding (Program)
import qualified Futhark.CodeGen.ImpCode.OpenCL as ImpOpenCL
import Futhark.MonadFreshNames
import Futhark.Util (zEncodeString)
import Futhark.Util.Pretty (pretty)

kernelsToCUDA, kernelsToOpenCL :: ImpKernels.Program
                               -> Either InternalError ImpOpenCL.Program
kernelsToCUDA = translateKernels TargetCUDA
kernelsToOpenCL = translateKernels TargetOpenCL

-- | Translate a kernels-program to an OpenCL-program.
translateKernels :: KernelTarget
                 -> ImpKernels.Program
                 -> Either InternalError ImpOpenCL.Program
translateKernels target (ImpKernels.Functions funs) = do
  (prog', ToOpenCL extra_funs kernels requirements sizes) <-
    runWriterT $ fmap Functions $ forM funs $ \(fname, fun) ->
    (fname,) <$> runReaderT (traverse (onHostOp target) fun) fname
  let kernel_names = M.keys kernels
      opencl_code = openClCode $ M.elems kernels
      opencl_prelude = pretty $ genPrelude target requirements
  return $ ImpOpenCL.Program opencl_code opencl_prelude kernel_names
    (S.toList $ kernelUsedTypes requirements) sizes $
    ImpOpenCL.Functions (M.toList extra_funs) <> prog'
  where genPrelude TargetOpenCL = genOpenClPrelude
        genPrelude TargetCUDA = genCUDAPrelude

pointerQuals ::  Monad m => String -> m [C.TypeQual]
pointerQuals "global"     = return [C.ctyquals|__global|]
pointerQuals "local"      = return [C.ctyquals|__local|]
pointerQuals "private"    = return [C.ctyquals|__private|]
pointerQuals "constant"   = return [C.ctyquals|__constant|]
pointerQuals "write_only" = return [C.ctyquals|__write_only|]
pointerQuals "read_only"  = return [C.ctyquals|__read_only|]
pointerQuals "kernel"     = return [C.ctyquals|__kernel|]
pointerQuals s            = fail $ "'" ++ s ++ "' is not an OpenCL kernel address space."

type UsedFunctions = [(String,C.Func)] -- The ordering is important!

newtype OpenClRequirements =
  OpenClRequirements { kernelUsedTypes :: S.Set PrimType }

instance Semigroup OpenClRequirements where
  OpenClRequirements ts1 <> OpenClRequirements ts2 =
    OpenClRequirements (ts1 <> ts2)

instance Monoid OpenClRequirements where
  mempty = OpenClRequirements mempty

data ToOpenCL = ToOpenCL { clExtraFuns :: M.Map Name ImpOpenCL.Function
                         , clKernels :: M.Map KernelName C.Func
                         , clRequirements :: OpenClRequirements
                         , clSizes :: M.Map Name SizeClass
                         }

instance Semigroup ToOpenCL where
  ToOpenCL f1 k1 r1 sz1 <> ToOpenCL f2 k2 r2 sz2 =
    ToOpenCL (f1<>f2) (k1<>k2) (r1<>r2) (sz1<>sz2)

instance Monoid ToOpenCL where
  mempty = ToOpenCL mempty mempty mempty mempty

type OnKernelM = ReaderT Name (WriterT ToOpenCL (Either InternalError))

onHostOp :: KernelTarget -> HostOp -> OnKernelM OpenCL
onHostOp target (CallKernel k) = onKernel target k
onHostOp _ (ImpKernels.GetSize v key size_class) = do
  tell mempty { clSizes = M.singleton key size_class }
  return $ ImpOpenCL.GetSize v key
onHostOp _ (ImpKernels.CmpSizeLe v key size_class x) = do
  tell mempty { clSizes = M.singleton key size_class }
  return $ ImpOpenCL.CmpSizeLe v key x
onHostOp _ (ImpKernels.GetSizeMax v size_class) =
  return $ ImpOpenCL.GetSizeMax v size_class

onKernel :: KernelTarget -> Kernel -> OnKernelM OpenCL

onKernel target kernel = do
  let (kernel_body, _) =
        GenericC.runCompilerM (Functions []) inKernelOperations blankNameSource mempty $
        GenericC.blockScope $ GenericC.compileCode $ kernelBody kernel

      use_params = mapMaybe useAsParam $ kernelUses kernel

      (local_memory_params, local_memory_init) =
        unzip $
        flip evalState (blankNameSource :: VNameSource) $
        mapM (prepareLocalMemory target) $ kernelLocalMemory kernel

      -- CUDA has very strict restrictions on the number of blocks
      -- permitted along the 'y' and 'z' dimensions of the grid
      -- (1<<16).  To work around this, we are going to dynamically
      -- permute the block dimensions to move the largest one to the
      -- 'x' dimension, which has a higher limit (1<<31).  This means
      -- we need to extend the kernel with extra parameters that
      -- contain information about this permutation, but we only do
      -- this for multidimensional kernels (at the time of this
      -- writing, only transposes).  The corresponding arguments are
      -- added automatically in CCUDA.hs.
      (perm_params, block_dim_init) =
        case (target, num_groups) of
          (TargetCUDA, [_, _, _]) -> ([[C.cparam|const int block_dim0|],
                                       [C.cparam|const int block_dim1|],
                                       [C.cparam|const int block_dim2|]],
                                      mempty)
          _ -> (mempty,
                [[C.citem|const int block_dim0 = 0;|],
                 [C.citem|const int block_dim1 = 1;|],
                 [C.citem|const int block_dim2 = 2;|]])

      params = perm_params ++ catMaybes local_memory_params ++ use_params

      const_defs = mapMaybe constDef $ kernelUses kernel

  tell mempty { clExtraFuns = mempty
              , clKernels = M.singleton name
                            [C.cfun|__kernel void $id:name ($params:params) {
                                $items:const_defs
                                $items:block_dim_init
                                $items:local_memory_init
                                $items:kernel_body
                                }|]
              , clRequirements = OpenClRequirements (typesInKernel kernel)
              }

  return $ LaunchKernel name (kernelArgs kernel) num_groups group_size
  where name = nameToString $ kernelName kernel
        num_groups = kernelNumGroups kernel
        group_size = kernelGroupSize kernel

        prepareLocalMemory TargetOpenCL (mem, Left _) = do
          mem_aligned <- newVName $ baseString mem ++ "_aligned"
          return (Just [C.cparam|__local volatile typename int64_t* $id:mem_aligned|],
                  [C.citem|__local volatile char* restrict $id:mem = $id:mem_aligned;|])
        prepareLocalMemory TargetOpenCL (mem, Right size) = do
          let size' = compilePrimExp size
          return (Nothing,
                  [C.citem|ALIGNED_LOCAL_MEMORY($id:mem, $exp:size');|])
        prepareLocalMemory TargetCUDA (mem, Left _) = do
          param <- newVName $ baseString mem ++ "_offset"
          return (Just [C.cparam|uint $id:param|],
                  [C.citem|volatile char *$id:mem = &shared_mem[$id:param];|])
        prepareLocalMemory TargetCUDA (mem, Right size) = do
          let size' = compilePrimExp size
          return (Nothing,
                  [CUDAC.citem|__shared__ volatile char $id:mem[$exp:size'];|])

useAsParam :: KernelUse -> Maybe C.Param
useAsParam (ScalarUse name bt) =
  let ctp = case bt of
        -- OpenCL does not permit bool as a kernel parameter type.
        Bool -> [C.cty|unsigned char|]
        _    -> GenericC.primTypeToCType bt
  in Just [C.cparam|$ty:ctp $id:name|]
useAsParam (MemoryUse name) =
  Just [C.cparam|__global unsigned char *$id:name|]
useAsParam ConstUse{} =
  Nothing

constDef :: KernelUse -> Maybe C.BlockItem
constDef (ConstUse v e) = Just [C.citem|const $ty:t $id:v = $exp:e';|]
  where t = GenericC.primTypeToCType $ primExpType e
        e' = compilePrimExp e
constDef _ = Nothing

openClCode :: [C.Func] -> String
openClCode kernels =
  pretty [C.cunit|$edecls:funcs|]
  where funcs =
          [[C.cedecl|$func:kernel_func|] |
           kernel_func <- kernels ]

genOpenClPrelude :: OpenClRequirements -> [C.Definition]
genOpenClPrelude (OpenClRequirements ts) =
  -- Clang-based OpenCL implementations need this for 'static' to work.
  [ [C.cedecl|$esc:("#ifdef cl_clang_storage_class_specifiers")|]
  , [C.cedecl|$esc:("#pragma OPENCL EXTENSION cl_clang_storage_class_specifiers : enable")|]
  , [C.cedecl|$esc:("#endif")|]
  , [C.cedecl|$esc:("#pragma OPENCL EXTENSION cl_khr_byte_addressable_store : enable")|]]
  ++
  [[C.cedecl|$esc:("#pragma OPENCL EXTENSION cl_khr_fp64 : enable")|] | uses_float64] ++
  [C.cunit|
/* Some OpenCL programs dislike empty progams, or programs with no kernels.
 * Declare a dummy kernel to ensure they remain our friends. */
__kernel void dummy_kernel(__global unsigned char *dummy, int n)
{
    const int thread_gid = get_global_id(0);
    if (thread_gid >= n) return;
}

typedef char int8_t;
typedef short int16_t;
typedef int int32_t;
typedef long int64_t;

typedef uchar uint8_t;
typedef ushort uint16_t;
typedef uint uint32_t;
typedef ulong uint64_t;

$esc:("#define ALIGNED_LOCAL_MEMORY(m,size) __local unsigned char m[size] __attribute__ ((align))")

// NVIDIAs OpenCL does not create device-wide memory fences (see #734), so we
// use inline assembly if we detect we are on an NVIDIA GPU.
$esc:("#ifdef cl_nv_pragma_unroll")
static inline void mem_fence_global() {
  asm("membar.gl;");
}
$esc:("#else")
static inline void mem_fence_global() {
  mem_fence(CLK_LOCAL_MEM_FENCE | CLK_GLOBAL_MEM_FENCE);
}
$esc:("#endif")
static inline void mem_fence_local() {
  mem_fence(CLK_LOCAL_MEM_FENCE);
}
|] ++
  cIntOps ++ cFloat32Ops ++ cFloat32Funs ++
  (if uses_float64 then cFloat64Ops ++ cFloat64Funs ++ cFloatConvOps else [])
  where uses_float64 = FloatType Float64 `S.member` ts


cudaAtomicOps :: [C.Definition]
cudaAtomicOps = (return mkOp <*> opNames <*> types) ++ extraOps
  where
    mkOp (clName, cuName) t =
      [C.cedecl|static inline $ty:t $id:clName(volatile $ty:t *p, $ty:t val) {
                 return $id:cuName(($ty:t *)p, val);
               }|]
    types = [ [C.cty|int|]
            , [C.cty|unsigned int|]
            , [C.cty|unsigned long long|]
            ]
    opNames = [ ("atomic_add",  "atomicAdd")
              , ("atomic_max",  "atomicMax")
              , ("atomic_min",  "atomicMin")
              , ("atomic_and",  "atomicAnd")
              , ("atomic_or",   "atomicOr")
              , ("atomic_xor",  "atomicXor")
              , ("atomic_xchg", "atomicExch")
              ]
    extraOps =
      [ [C.cedecl|static inline $ty:t atomic_cmpxchg(volatile $ty:t *p, $ty:t cmp, $ty:t val) {
                  return atomicCAS(($ty:t *)p, cmp, val);
                }|] | t <- types]

genCUDAPrelude :: OpenClRequirements -> [C.Definition]
genCUDAPrelude (OpenClRequirements _) =
  cudafy ++ cudaAtomicOps ++ ops
  where ops = cIntOps ++ cFloat32Ops ++ cFloat32Funs ++ cFloat64Ops
                ++ cFloat64Funs ++ cFloatConvOps
        cudafy = [CUDAC.cunit|
typedef char int8_t;
typedef short int16_t;
typedef int int32_t;
typedef long int64_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef uint8_t uchar;
typedef uint16_t ushort;
typedef uint32_t uint;
typedef uint64_t ulong;
$esc:("#define __kernel extern \"C\" __global__ __launch_bounds__(MAX_THREADS_PER_BLOCK)")
$esc:("#define __global")
$esc:("#define __local")
$esc:("#define __private")
$esc:("#define __constant")
$esc:("#define __write_only")
$esc:("#define __read_only")

static inline int get_group_id_fn(int block_dim0, int block_dim1, int block_dim2, int d)
{
  switch (d) {
    case 0: d = block_dim0; break;
    case 1: d = block_dim1; break;
    case 2: d = block_dim2; break;
  }
  switch (d) {
    case 0: return blockIdx.x;
    case 1: return blockIdx.y;
    case 2: return blockIdx.z;
    default: return 0;
  }
}
$esc:("#define get_group_id(d) get_group_id_fn(block_dim0, block_dim1, block_dim2, d)")

static inline int get_num_groups_fn(int block_dim0, int block_dim1, int block_dim2, int d)
{
  switch (d) {
    case 0: d = block_dim0; break;
    case 1: d = block_dim1; break;
    case 2: d = block_dim2; break;
  }
  switch(d) {
    case 0: return gridDim.x;
    case 1: return gridDim.y;
    case 2: return gridDim.z;
    default: return 0;
  }
}
$esc:("#define get_num_groups(d) get_num_groups_fn(block_dim0, block_dim1, block_dim2, d)")

static inline int get_local_id(int d)
{
  switch (d) {
    case 0: return threadIdx.x;
    case 1: return threadIdx.y;
    case 2: return threadIdx.z;
    default: return 0;
  }
}

static inline int get_local_size(int d)
{
  switch (d) {
    case 0: return blockDim.x;
    case 1: return blockDim.y;
    case 2: return blockDim.z;
    default: return 0;
  }
}

static inline int get_global_id_fn(int block_dim0, int block_dim1, int block_dim2, int d)
{
  return get_group_id(d) * get_local_size(d) + get_local_id(d);
}
$esc:("#define get_global_id(d) get_global_id_fn(block_dim0, block_dim1, block_dim2, d)")

static inline int get_global_size(int block_dim0, int block_dim1, int block_dim2, int d)
{
  return get_num_groups(d) * get_local_size(d);
}

$esc:("#define CLK_LOCAL_MEM_FENCE 1")
$esc:("#define CLK_GLOBAL_MEM_FENCE 2")
static inline void barrier(int x)
{
  __syncthreads();
}
static inline void mem_fence_local() {
  __threadfence_block();
}
static inline void mem_fence_global() {
  __threadfence();
}
$esc:("#define NAN (0.0/0.0)")
$esc:("#define INFINITY (1.0/0.0)")
extern volatile __shared__ char shared_mem[];
|]

compilePrimExp :: PrimExp KernelConst -> C.Exp
compilePrimExp e = runIdentity $ GenericC.compilePrimExp compileKernelConst e
  where compileKernelConst (SizeConst key) =
          return [C.cexp|$id:(zEncodeString (pretty key))|]

kernelArgs :: Kernel -> [KernelArg]
kernelArgs kernel =
  mapMaybe (fmap (SharedMemoryKArg . memSizeToExp) . localMemorySize)
  (kernelLocalMemory kernel) ++
  mapMaybe useToArg (kernelUses kernel)
  where localMemorySize (_, Left size) = Just size
        localMemorySize (_, Right{}) = Nothing

--- Generating C

inKernelOperations :: GenericC.Operations KernelOp UsedFunctions
inKernelOperations = GenericC.Operations
                     { GenericC.opsCompiler = kernelOps
                     , GenericC.opsMemoryType = kernelMemoryType
                     , GenericC.opsWriteScalar = GenericC.writeScalarPointerWithQuals pointerQuals
                     , GenericC.opsReadScalar = GenericC.readScalarPointerWithQuals pointerQuals
                     , GenericC.opsAllocate = cannotAllocate
                     , GenericC.opsDeallocate = cannotDeallocate
                     , GenericC.opsCopy = copyInKernel
                     , GenericC.opsStaticArray = noStaticArrays
                     , GenericC.opsFatMemory = False
                     }
  where kernelOps :: GenericC.OpCompiler KernelOp UsedFunctions
        kernelOps (GetGroupId v i) =
          GenericC.stm [C.cstm|$id:v = get_group_id($int:i);|]
        kernelOps (GetLocalId v i) =
          GenericC.stm [C.cstm|$id:v = get_local_id($int:i);|]
        kernelOps (GetLocalSize v i) =
          GenericC.stm [C.cstm|$id:v = get_local_size($int:i);|]
        kernelOps (GetGlobalId v i) =
          GenericC.stm [C.cstm|$id:v = get_global_id($int:i);|]
        kernelOps (GetGlobalSize v i) =
          GenericC.stm [C.cstm|$id:v = get_global_size($int:i);|]
        kernelOps (GetLockstepWidth v) =
          GenericC.stm [C.cstm|$id:v = LOCKSTEP_WIDTH;|]
        kernelOps LocalBarrier =
          GenericC.stm [C.cstm|barrier(CLK_LOCAL_MEM_FENCE);|]
        kernelOps GlobalBarrier =
          GenericC.stm [C.cstm|barrier(CLK_GLOBAL_MEM_FENCE);|]
        kernelOps MemFence =
          GenericC.stm [C.cstm|mem_fence_global();|]
        kernelOps (Atomic space aop) = atomicOps space aop

        atomicOps s (AtomicAdd old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_add($esc:(atomicCast s "int")&$id:arr[$exp:ind'], $exp:val');|]

        atomicOps s (AtomicSMax old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_max($esc:(atomicCast s "int")&$id:arr[$exp:ind'], $exp:val');|]

        atomicOps s (AtomicSMin old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_min($esc:(atomicCast s "int")&$id:arr[$exp:ind'], $exp:val');|]

        atomicOps s (AtomicUMax old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_max($esc:(atomicCast s "unsigned int")&$id:arr[$exp:ind'], (unsigned int)$exp:val');|]

        atomicOps s (AtomicUMin old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_min($esc:(atomicCast s "unsigned int")&$id:arr[$exp:ind'], (unsigned int)$exp:val');|]

        atomicOps s (AtomicAnd old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_and($esc:(atomicCast s "unsigned int")&$id:arr[$exp:ind'], (unsigned int)$exp:val');|]

        atomicOps s (AtomicOr old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_or($esc:(atomicCast s "unsigned int")&$id:arr[$exp:ind'], (unsigned int)$exp:val');|]

        atomicOps s (AtomicXor old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_xor($esc:(atomicCast s "unsigned int")&$id:arr[$exp:ind'], (unsigned int)$exp:val');|]

        atomicOps s (AtomicCmpXchg old arr ind cmp val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          cmp' <- GenericC.compileExp cmp
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_cmpxchg($esc:(atomicCast s "int")&$id:arr[$exp:ind'], $exp:cmp', $exp:val');|]

        atomicOps s (AtomicXchg old arr ind val) = do
          ind' <- GenericC.compileExp $ innerExp ind
          val' <- GenericC.compileExp val
          GenericC.stm [C.cstm|$id:old = atomic_xchg($esc:(atomicCast s "int")&$id:arr[$exp:ind'], $exp:val');|]

        atomicCast s bt = "(" ++ unwords [ "volatile"
                                         , "__" ++ case space of
                                                     DefaultSpace -> "global"
                                                     Space sid -> sid
                                         , bt
                                         , "*"
                                         ] ++ ")"
        cannotAllocate :: GenericC.Allocate KernelOp UsedFunctions
        cannotAllocate _ =
          fail "Cannot allocate memory in kernel"

        cannotDeallocate :: GenericC.Deallocate KernelOp UsedFunctions
        cannotDeallocate _ _ =
          fail "Cannot deallocate memory in kernel"

        copyInKernel :: GenericC.Copy KernelOp UsedFunctions
        copyInKernel _ _ _ _ _ _ _ =
          fail "Cannot bulk copy in kernel."

        noStaticArrays :: GenericC.StaticArray KernelOp UsedFunctions
        noStaticArrays _ _ _ _ =
          fail "Cannot create static array in kernel."

        kernelMemoryType space = do
          quals <- pointerQuals space
          return [C.cty|$tyquals:quals $ty:defaultMemBlockType|]

--- Checking requirements

useToArg :: KernelUse -> Maybe KernelArg
useToArg (MemoryUse mem)  = Just $ MemKArg mem
useToArg (ScalarUse v bt) = Just $ ValueKArg (LeafExp (ScalarVar v) bt) bt
useToArg ConstUse{}       = Nothing

typesInKernel :: Kernel -> S.Set PrimType
typesInKernel kernel = typesInCode $ kernelBody kernel

typesInCode :: ImpKernels.KernelCode -> S.Set PrimType
typesInCode Skip = mempty
typesInCode (c1 :>>: c2) = typesInCode c1 <> typesInCode c2
typesInCode (For _ it e c) = IntType it `S.insert` typesInExp e <> typesInCode c
typesInCode (While e c) = typesInExp e <> typesInCode c
typesInCode DeclareMem{} = mempty
typesInCode (DeclareScalar _ t) = S.singleton t
typesInCode (DeclareArray _ _ t _) = S.singleton t
typesInCode (Allocate _ (Count e) _) = typesInExp e
typesInCode Free{} = mempty
typesInCode (Copy _ (Count e1) _ _ (Count e2) _ (Count e3)) =
  typesInExp e1 <> typesInExp e2 <> typesInExp e3
typesInCode (Write _ (Count e1) t _ _ e2) =
  typesInExp e1 <> S.singleton t <> typesInExp e2
typesInCode (SetScalar _ e) = typesInExp e
typesInCode SetMem{} = mempty
typesInCode (Call _ _ es) = mconcat $ map typesInArg es
  where typesInArg MemArg{} = mempty
        typesInArg (ExpArg e) = typesInExp e
typesInCode (If e c1 c2) =
  typesInExp e <> typesInCode c1 <> typesInCode c2
typesInCode (Assert e _ _) = typesInExp e
typesInCode (Comment _ c) = typesInCode c
typesInCode (DebugPrint _ _ e) = typesInExp e
typesInCode Op{} = mempty

typesInExp :: Exp -> S.Set PrimType
typesInExp (ValueExp v) = S.singleton $ primValueType v
typesInExp (BinOpExp _ e1 e2) = typesInExp e1 <> typesInExp e2
typesInExp (CmpOpExp _ e1 e2) = typesInExp e1 <> typesInExp e2
typesInExp (ConvOpExp op e) = S.fromList [from, to] <> typesInExp e
  where (from, to) = convOpType op
typesInExp (UnOpExp _ e) = typesInExp e
typesInExp (FunExp _ args t) = S.singleton t <> mconcat (map typesInExp args)
typesInExp (LeafExp (Index _ (Count e) t _ _) _) = S.singleton t <> typesInExp e
typesInExp (LeafExp ScalarVar{} _) = mempty
typesInExp (LeafExp (SizeOf t) _) = S.singleton t
