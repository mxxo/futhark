-- Local functions should not have their (overloaded) record type fixed
-- immediately.
-- ==
-- input { 2 3 } output { 2 }

let main (x: i32) (y: i32) =
  let f v = v.1
  in f (x,y)
