-- | The raw-bytes fixture module (issue #27).
-- |
-- | `rt.abi.callBytes`/`call` hand a callee a PureScript `String`, so a caller
-- | carrying bytes has to hand them over as text -- which they are not in
-- | general. `rt.abi.callRaw` hands each argument over as an `Array Int` with
-- | one integer per byte instead, so nothing on the path has to be text.
-- |
-- | Two functions, both about bytes as `Int`s:
-- |
-- |   * `echoByte` -- the caller gets its own bytes back, byte for byte. With
-- |     `[0xff, 0x00, 0xfe]` that is a reply containing bytes no `String` can
-- |     hold;
-- |   * `firstByte` -- a compiled PureScript function actually READS a byte out
-- |     of the array it was given, which is what proves the representation is
-- |     usable and not merely transferable.
-- |
-- | Prelude only, on purpose: an import outside the packages the fixture project
-- | resolves would fail `spago build` and take every gate down with it. That is
-- | why the cases below are LITERAL array patterns and not `Maybe`/`Data.Array`:
-- | `Data.Maybe` and `Data.Array` are not reachable from here.
-- |
-- | `b : _` is not available either -- `:` is `List`'s pattern synonym, and a
-- | module that does not import `Data.List` does not have it; purs rejects the
-- | whole module with `Unknown operator (:)`. Literal array patterns (`[b]`,
-- | `[b, _]`, ...) are the Prelude-only way to take an array apart, so
-- | `firstByte` covers the lengths a byte fixture can start with.
module Bytes where

import Prelude

-- A byte round trip: the caller must get its own bytes back, byte for byte.
echoByte :: Array Int -> Array Int
echoByte xs = xs

-- Reads the byte at index 0, or -1 when the array is empty.
-- Implemented with Prelude only: no Maybe, no Data.Array, no cons pattern.
firstByte :: Array Int -> Int
firstByte a = case a of
  [] -> -1
  [b] -> b
  [b, _] -> b
  [b, _, _] -> b
  _ -> -1
