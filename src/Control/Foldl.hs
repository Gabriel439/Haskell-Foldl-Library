{-| This module provides efficient and streaming left folds that you can combine
    using 'Applicative' style.

    Import this module qualified to avoid clashing with the Prelude:

>>> import qualified Control.Foldl as L

    Use 'fold' to apply a 'Fold' to a list:

>>> L.fold L.sum [1..100]
5050

    'Fold's are 'Applicative's, so you can combine them using 'Applicative'
    combinators:

>>> import Control.Applicative
>>> let average = (/) <$> L.sum <*> L.genericLength

    These combined folds will still traverse the list only once, streaming
    efficiently over the list in constant space without space leaks:

>>> L.fold average [1..10000000]
5000000.5
>>> L.fold ((,) <$> L.minimum <*> L.maximum) [1..10000000]
(Just 1,Just 10000000)

-}

{-# LANGUAGE ExistentialQuantification, RankNTypes, Trustworthy #-}

module Control.Foldl (
    -- * Fold Types
      Fold(..)
    , FoldM(..)

    -- * Folding
    , fold
    , foldM
    , scan
    , scannify

    -- * Folds
    , mconcat
    , foldMap
    , head
    , last
    , lastDef
    , null
    , length
    , and
    , or
    , all
    , any
    , sum
    , product
    , maximum
    , minimum
    , elem
    , notElem
    , find
    , index
    , elemIndex
    , findIndex

    -- * Generic Folds
    , genericLength
    , genericIndex

    -- * Container folds
    , list
    , nub
    , eqNub
    , set
    , vector

    -- * Utilities
    -- $utilities
    , purely
    , impurely
    , generalize
    , simplify
    , premap
    , premapM
    , pretraverse
    , pretraverseM

    -- * Re-exports
    -- $reexports
    , module Control.Monad.Primitive
    , module Data.Foldable
    , module Data.Vector.Generic
    ) where

import Control.Applicative (Applicative(pure, (<*>)),liftA2)
import Control.Foldl.Internal (Maybe'(..), lazy, Either'(..), hush)
import Control.Monad ((<=<))
import Control.Monad.Primitive (PrimMonad)
import Data.Foldable (Foldable)
import qualified Data.Foldable as F
import Data.Functor.Constant (Constant(Constant, getConstant))
import Data.Functor.Identity (Identity, runIdentity)
import Data.Monoid (Monoid(mempty, mappend), Endo(Endo, appEndo))
import Data.Vector.Generic (Vector)
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.List as List
import qualified Data.Set as Set
import Prelude hiding
    ( head
    , last
    , null
    , length
    , and
    , or
    , all
    , any
    , sum
    , product
    , maximum
    , minimum
    , elem
    , notElem
    )

{-| Efficient representation of a left fold that preserves the fold's step
    function, initial accumulator, and extraction function

    This allows the 'Applicative' instance to assemble derived folds that
    traverse the container only once

    A \''Fold' a b\' processes elements of type __a__ and results in a
    value of type __b__.
-}
data Fold a b
  -- | @Fold @ @ step @ @ initial @ @ extract@
  = forall x. Fold (x -> a -> x) x (x -> b)

data Pair a b = Pair !a !b

instance Functor (Fold a) where
    fmap f (Fold step begin done) = Fold step begin (f . done)
    {-# INLINABLE fmap #-}

instance Applicative (Fold a) where
    pure b    = Fold (\() _ -> ()) () (\() -> b)
    {-# INLINABLE pure #-}

    (Fold stepL beginL doneL) <*> (Fold stepR beginR doneR) =
        let step (Pair xL xR) a = Pair (stepL xL a) (stepR xR a)
            begin = Pair beginL beginR
            done (Pair xL xR) = doneL xL (doneR xR)
        in  Fold step begin done
    {-# INLINABLE (<*>) #-}

instance Monoid b => Monoid (Fold a b) where
    mempty = pure mempty
    {-# INLINABLE mempty #-}

    mappend = liftA2 mappend
    {-# INLINABLE mappend #-}

instance Num b => Num (Fold a b) where
    fromInteger = pure . fromInteger
    {-# INLINABLE fromInteger #-}

    negate = fmap negate
    {-# INLINABLE negate #-}

    abs = fmap abs
    {-# INLINABLE abs #-}

    signum = fmap signum
    {-# INLINABLE signum #-}

    (+) = liftA2 (+)
    {-# INLINABLE (+) #-}

    (*) = liftA2 (*)
    {-# INLINABLE (*) #-}

    (-) = liftA2 (-)
    {-# INLINABLE (-) #-}

instance Fractional b => Fractional (Fold a b) where
    fromRational = pure . fromRational
    {-# INLINABLE fromRational #-}

    recip = fmap recip
    {-# INLINABLE recip #-}

    (/) = liftA2 (/)
    {-# INLINABLE (/) #-}

instance Floating b => Floating (Fold a b) where
    pi = pure pi
    {-# INLINABLE pi #-}

    exp = fmap exp
    {-# INLINABLE exp #-}

    sqrt = fmap sqrt
    {-# INLINABLE sqrt #-}

    log = fmap log
    {-# INLINABLE log #-}

    sin = fmap sin
    {-# INLINABLE sin #-}

    tan = fmap tan
    {-# INLINABLE tan #-}

    cos = fmap cos
    {-# INLINABLE cos #-}

    asin = fmap sin
    {-# INLINABLE asin #-}

    atan = fmap atan
    {-# INLINABLE atan #-}

    acos = fmap acos
    {-# INLINABLE acos #-}

    sinh = fmap sinh
    {-# INLINABLE sinh #-}

    tanh = fmap tanh
    {-# INLINABLE tanh #-}

    cosh = fmap cosh
    {-# INLINABLE cosh #-}

    asinh = fmap asinh
    {-# INLINABLE asinh #-}

    atanh = fmap atanh
    {-# INLINABLE atanh #-}

    acosh = fmap acosh
    {-# INLINABLE acosh #-}

    (**) = liftA2 (**)
    {-# INLINABLE (**) #-}

    logBase = liftA2 logBase
    {-# INLINABLE logBase #-}

{-| Like 'Fold', but monadic.

    A \''FoldM' m a b\' processes elements of type __a__ and
    results in a monadic value of type __m b__.
-}
data FoldM m a b =
  -- | @FoldM @ @ step @ @ initial @ @ extract@
  forall x . FoldM (x -> a -> m x) (m x) (x -> m b)

instance Monad m => Functor (FoldM m a) where
    fmap f (FoldM step start done) = FoldM step start done'
      where
        done' x = do
            b <- done x
            return $! f b
    {-# INLINABLE fmap #-}

instance Monad m => Applicative (FoldM m a) where
    pure b = FoldM (\() _ -> return ()) (return ()) (\() -> return b)
    {-# INLINABLE pure #-}

    (FoldM stepL beginL doneL) <*> (FoldM stepR beginR doneR) =
        let step (Pair xL xR) a = do
                xL' <- stepL xL a
                xR' <- stepR xR a
                return $! Pair xL' xR'
            begin = do
                xL <- beginL
                xR <- beginR
                return $! Pair xL xR
            done (Pair xL xR) = do
                f <- doneL xL
                x <- doneR xR
                return $! f x
        in  FoldM step begin done
    {-# INLINABLE (<*>) #-}

instance (Monoid b, Monad m) => Monoid (FoldM m a b) where
    mempty = pure mempty
    {-# INLINABLE mempty #-}

    mappend = liftA2 mappend
    {-# INLINABLE mappend #-}

instance (Monad m, Num b) => Num (FoldM m a b) where
    fromInteger = pure . fromInteger
    {-# INLINABLE fromInteger #-}

    negate = fmap negate
    {-# INLINABLE negate #-}

    abs = fmap abs
    {-# INLINABLE abs #-}

    signum = fmap signum
    {-# INLINABLE signum #-}

    (+) = liftA2 (+)
    {-# INLINABLE (+) #-}

    (*) = liftA2 (*)
    {-# INLINABLE (*) #-}

    (-) = liftA2 (-)
    {-# INLINABLE (-) #-}

instance (Monad m, Fractional b) => Fractional (FoldM m a b) where
    fromRational = pure . fromRational
    {-# INLINABLE fromRational #-}

    recip = fmap recip
    {-# INLINABLE recip #-}

    (/) = liftA2 (/)
    {-# INLINABLE (/) #-}

instance (Monad m, Floating b) => Floating (FoldM m a b) where
    pi = pure pi
    {-# INLINABLE pi #-}

    exp = fmap exp
    {-# INLINABLE exp #-}

    sqrt = fmap sqrt
    {-# INLINABLE sqrt #-}

    log = fmap log
    {-# INLINABLE log #-}

    sin = fmap sin
    {-# INLINABLE sin #-}

    tan = fmap tan
    {-# INLINABLE tan #-}

    cos = fmap cos
    {-# INLINABLE cos #-}

    asin = fmap sin
    {-# INLINABLE asin #-}

    atan = fmap atan
    {-# INLINABLE atan #-}

    acos = fmap acos
    {-# INLINABLE acos #-}

    sinh = fmap sinh
    {-# INLINABLE sinh #-}

    tanh = fmap tanh
    {-# INLINABLE tanh #-}

    cosh = fmap cosh
    {-# INLINABLE cosh #-}

    asinh = fmap asinh
    {-# INLINABLE asinh #-}

    atanh = fmap atanh
    {-# INLINABLE atanh #-}

    acosh = fmap acosh
    {-# INLINABLE acosh #-}

    (**) = liftA2 (**)
    {-# INLINABLE (**) #-}

    logBase = liftA2 logBase
    {-# INLINABLE logBase #-}

-- | Apply a strict left 'Fold' to a 'Foldable' container
fold :: Foldable f => Fold a b -> f a -> b
fold (Fold step begin done) as = F.foldr cons done as begin
  where
    cons a k x = k $! step x a
{-# INLINE fold #-}

-- | Like 'fold', but monadic
foldM :: (Foldable f, Monad m) => FoldM m a b -> f a -> m b
foldM (FoldM step begin done) as0 = do
    x0 <- begin
    F.foldr step' done as0 $! x0
  where
    step' a k x = do
        x' <- step x a
        k $! x'
{-# INLINE foldM #-}

-- | Convert a strict left 'Fold' into a scan
scan :: Fold a b -> [a] -> [b]
scan (Fold step begin done) as = foldr cons nil as begin
  where
    nil      x = done x:[]
    cons a k x = done x:(k $! step x a)
{-# INLINE scan #-}

-- | Convert a fold into a fold which produces all intermediate values in a list.
--   Note that this derived fold will run the provided fold's finalizer function
--   on every step; beware asymptotic inefficiency when applying to a fold which
--   has a finalizer which runs in greater than constant time.
scannify :: Fold a b -> Fold a [b]
scannify (Fold step begin done) = Fold step' begin' done'
  where
    step' (x, list) a = (step x a, list . (done x :))
    begin' = (begin, id)
    done' (x, list) = done x : list []

-- | Fold all values within a container using 'mappend' and 'mempty'
mconcat :: Monoid a => Fold a a
mconcat = Fold mappend mempty id
{-# INLINABLE mconcat #-}

-- | Convert a \"@foldMap@\" to a 'Fold'
foldMap :: Monoid w => (a -> w) -> (w -> b) -> Fold a b
foldMap to = Fold (\x a -> mappend x (to a)) mempty
{-# INLINABLE foldMap #-}

{-| Get the first element of a container or return 'Nothing' if the container is
    empty
-}
head :: Fold a (Maybe a)
head = Fold step Nothing' lazy
  where
    step x a = case x of
        Nothing' -> Just' a
        _        -> x
{-# INLINABLE head #-}

{-| Get the last element of a container or return 'Nothing' if the container is
    empty
-}
last :: Fold a (Maybe a)
last = Fold (const Just') Nothing' lazy
{-# INLINABLE last #-}

{-| Get the last element of a container or return a default value if the container
    is empty
-}
lastDef :: a -> Fold a a
lastDef a = Fold (\_ a' -> a') a id
{-# INLINABLE lastDef #-}

-- | Returns 'True' if the container is empty, 'False' otherwise
null :: Fold a Bool
null = Fold (\_ _ -> False) True id
{-# INLINABLE null #-}

-- | Return the length of the container
length :: Fold a Int
length = genericLength
{- Technically, 'length' is just 'genericLength' specialized to 'Int's.  I keep
   the two separate so that I can later provide an 'Int'-specialized
   implementation of 'length' for performance reasons like "GHC.List" does
   without breaking backwards compatibility.
-}
{-# INLINABLE length #-}

-- | Returns 'True' if all elements are 'True', 'False' otherwise
and :: Fold Bool Bool
and = Fold (&&) True id
{-# INLINABLE and #-}

-- | Returns 'True' if any element is 'True', 'False' otherwise
or :: Fold Bool Bool
or = Fold (||) False id
{-# INLINABLE or #-}

{-| @(all predicate)@ returns 'True' if all elements satisfy the predicate,
    'False' otherwise
-}
all :: (a -> Bool) -> Fold a Bool
all predicate = Fold (\x a -> x && predicate a) True id
{-# INLINABLE all #-}

{-| @(any predicate)@ returns 'True' if any element satisfies the predicate,
    'False' otherwise
-}
any :: (a -> Bool) -> Fold a Bool
any predicate = Fold (\x a -> x || predicate a) False id
{-# INLINABLE any #-}

-- | Computes the sum of all elements
sum :: Num a => Fold a a
sum = Fold (+) 0 id
{-# INLINABLE sum #-}

-- | Computes the product all elements
product :: Num a => Fold a a
product = Fold (*) 1 id
{-# INLINABLE product #-}

-- | Computes the maximum element
maximum :: Ord a => Fold a (Maybe a)
maximum = Fold step Nothing' lazy
  where
    step x a = Just' (case x of
        Nothing' -> a
        Just' a' -> max a' a)
{-# INLINABLE maximum #-}

-- | Computes the minimum element
minimum :: Ord a => Fold a (Maybe a)
minimum = Fold step Nothing' lazy
  where
    step x a = Just' (case x of
        Nothing' -> a
        Just' a' -> min a' a)
{-# INLINABLE minimum #-}

{-| @(elem a)@ returns 'True' if the container has an element equal to @a@,
    'False' otherwise
-}
elem :: Eq a => a -> Fold a Bool
elem a = any (a ==)
{-# INLINABLE elem #-}

{-| @(notElem a)@ returns 'False' if the container has an element equal to @a@,
    'True' otherwise
-}
notElem :: Eq a => a -> Fold a Bool
notElem a = all (a /=)
{-# INLINABLE notElem #-}

{-| @(find predicate)@ returns the first element that satisfies the predicate or
    'Nothing' if no element satisfies the predicate
-}
find :: (a -> Bool) -> Fold a (Maybe a)
find predicate = Fold step Nothing' lazy
  where
    step x a = case x of
        Nothing' -> if predicate a then Just' a else Nothing'
        _        -> x
{-# INLINABLE find #-}

{-| @(index n)@ returns the @n@th element of the container, or 'Nothing' if the
    container has an insufficient number of elements
-}
index :: Int -> Fold a (Maybe a)
index = genericIndex
{-# INLINABLE index #-}

{-| @(elemIndex a)@ returns the index of the first element that equals @a@, or
    'Nothing' if no element matches
-}
elemIndex :: Eq a => a -> Fold a (Maybe Int)
elemIndex a = findIndex (a ==)
{-# INLINABLE elemIndex #-}

{-| @(findIndex predicate)@ returns the index of the first element that
    satisfies the predicate, or 'Nothing' if no element satisfies the predicate
-}
findIndex :: (a -> Bool) -> Fold a (Maybe Int)
findIndex predicate = Fold step (Left' 0) hush
  where
    step x a = case x of
        Left' i ->
            if predicate a
            then Right' i
            else Left' (i + 1)
        _       -> x
{-# INLINABLE findIndex #-}

-- | Like 'length', except with a more general 'Num' return value
genericLength :: Num b => Fold a b
genericLength = Fold (\n _ -> n + 1) 0 id
{-# INLINABLE genericLength #-}

-- | Like 'index', except with a more general 'Integral' argument
genericIndex :: Integral i => i -> Fold a (Maybe a)
genericIndex i = Fold step (Left' 0) done
  where
    step x a = case x of
        Left'  j -> if i == j then Right' a else Left' (j + 1)
        _        -> x
    done x = case x of
        Left'  _ -> Nothing
        Right' a -> Just a
{-# INLINABLE genericIndex #-}

-- | Fold all values into a list
list :: Fold a [a]
list = Fold (\x a -> x . (a:)) id ($ [])
{-# INLINABLE list #-}

{-| /O(n log n)/.  Fold values into a list with duplicates removed, while
    preserving their first occurrences
-}
nub :: Ord a => Fold a [a]
nub = Fold step (Pair Set.empty id) fin
  where
    step (Pair s r) a = if Set.member a s
      then Pair s r
      else Pair (Set.insert a s) (r . (a :))
    fin (Pair _ r) = r []
{-# INLINABLE nub #-}

{-| /O(n^2)/.  Fold values into a list with duplicates removed, while preserving
    their first occurrences
-}
eqNub :: Eq a => Fold a [a]
eqNub = Fold step (Pair [] id) fin
  where
    step (Pair known r) a = if List.elem a known
      then Pair known r
      else Pair (a : known) (r . (a :))
    fin (Pair _ r) = r []
{-# INLINABLE eqNub #-}

-- | Fold values into a set
set :: Ord a => Fold a (Set.Set a)
set = Fold (flip Set.insert) Set.empty id
{-# INLINABLE set #-}

maxChunkSize :: Int
maxChunkSize = 8 * 1024 * 1024

-- | Fold all values into a vector
vector :: (PrimMonad m, Vector v a) => FoldM m a (v a)
vector = FoldM step begin done
  where
    begin = do
        mv <- M.unsafeNew 10
        return (Pair mv 0)
    step (Pair mv idx) a = do
        let len = M.length mv
        mv' <- if idx >= len
            then M.unsafeGrow mv (min len maxChunkSize)
            else return mv
        M.unsafeWrite mv' idx a
        return (Pair mv' (idx + 1))
    done (Pair mv idx) = do
        v <- V.unsafeFreeze mv
        return (V.unsafeTake idx v)
{-# INLINABLE vector #-}

{- $utilities
    'purely' and 'impurely' allow you to write folds compatible with the @foldl@
    library without incurring a @foldl@ dependency.  Write your fold to accept
    three parameters corresponding to the step function, initial
    accumulator, and extraction function and then users can upgrade your
    function to accept a 'Fold' or 'FoldM' using the 'purely' or 'impurely'
    combinators.

    For example, the @pipes@ library implements a @foldM@ function in
    @Pipes.Prelude@ with the following type:

> foldM
>     :: Monad m
>     => (x -> a -> m x) -> m x -> (x -> m b) -> Producer a m () -> m b

    @foldM@ is set up so that you can wrap it with 'impurely' to accept a
    'FoldM' instead:

> impurely foldM :: Monad m => FoldM m a b -> Producer a m () -> m b
-}

-- | Upgrade a fold to accept the 'Fold' type
purely :: (forall x . (x -> a -> x) -> x -> (x -> b) -> r) -> Fold a b -> r
purely f (Fold step begin done) = f step begin done
{-# INLINABLE purely #-}

-- | Upgrade a monadic fold to accept the 'FoldM' type
impurely
    :: Monad m
    => (forall x . (x -> a -> m x) -> m x -> (x -> m b) -> r)
    -> FoldM m a b
    -> r
impurely f (FoldM step begin done) = f step begin done
{-# INLINABLE impurely #-}

{-| Generalize a `Fold` to a `FoldM`

> generalize (pure r) = pure r
>
> generalize (f <*> x) = generalize f <*> generalize x
-}
generalize :: Monad m => Fold a b -> FoldM m a b
generalize (Fold step begin done) = FoldM step' begin' done'
  where
    step' x a = return (step x a)
    begin'    = return  begin
    done' x   = return (done x)
{-# INLINABLE generalize #-}

{-| Simplify a pure `FoldM` to a `Fold`

> simplify (pure r) = pure r
>
> simplify (f <*> x) = simplify f <*> simplify x
-}
simplify :: FoldM Identity a b -> Fold a b
simplify (FoldM step begin done) = Fold step' begin' done'
  where
    step' x a = runIdentity (step x a)
    begin'    = runIdentity  begin
    done' x   = runIdentity (done x)
{-# INLINABLE simplify #-}

{-| @(premap f folder)@ returns a new 'Fold' where f is applied at each step

> fold (premap f folder) list = fold folder (map f list)

>>> fold (premap Sum mconcat) [1..10]
Sum {getSum = 55}

>>> fold mconcat (map Sum [1..10])
Sum {getSum = 55}

> premap id = id
>
> premap (f . g) = premap g . premap f

> premap k (pure r) = pure r
>
> premap k (f <*> x) = premap k f <*> premap k x
-}
premap :: (a -> b) -> Fold b r -> Fold a r
premap f (Fold step begin done) = Fold step' begin done
  where
    step' x a = step x (f a)
{-# INLINABLE premap #-}

{-| @(premapM f folder)@ returns a new 'FoldM' where f is applied to each input
    element

> foldM (premapM f folder) list = foldM folder (map f list)

> premapM id = id
>
> premapM (f . g) = premap g . premap f

> premapM k (pure r) = pure r
>
> premapM k (f <*> x) = premapM k f <*> premapM k x
-}
premapM :: Monad m => (a -> b) -> FoldM m b r -> FoldM m a r
premapM f (FoldM step begin done) = FoldM step' begin done
  where
    step' x a = step x (f a)
{-# INLINABLE premapM #-}

type Traversal' a b = forall f . Applicative f => (b -> f b) -> a -> f a

{-| @(pretraverse t folder)@ traverses each incoming element using @Traversal'@
    @t@ and folds every target of the @Traversal'@

>>> fold (pretraverse traverse sum) [[1..5],[6..10]]
55

>>> fold (pretraverse (traverse.traverse) sum) [[Nothing, Just 2, Just 7],[Just 13, Nothing, Just 20]]
42

>>> fold (pretraverse (filtered even) sum) [1,3,5,7,21,21]
42

>>> fold (pretraverse _2 mconcat) [(1,"Hello "),(2,"World"),(3,"!")]
"Hello World!"

> pretraverse id = id
>
> pretraverse (f . g) = pretraverse f . pretraverse g

> pretraverse t (pure r) = pure r
>
> pretraverse t (f <*> x) = pretraverse t f <*> pretraverse t x
-}
pretraverse :: Traversal' a b -> Fold b r -> Fold a r
pretraverse k (Fold step begin done) = Fold step' begin done
  where
    step' = flip (appEndo . getConstant . k (Constant . Endo . flip step))
{-# INLINABLE pretraverse #-}

newtype EndoM m a = EndoM { appEndoM :: a -> m a }

instance Monad m => Monoid (EndoM m a) where
    mempty = EndoM return
    mappend (EndoM f) (EndoM g) = EndoM (f <=< g)

{-| @(pretraverseM t folder)@ traverses each incoming element using @Traversal'@
    @t@ and folds every target of the @Traversal'@

> pretraverseM id = id
>
> pretraverseM (f . g) = pretraverseM f . pretraverseM g

> pretraverseM t (pure r) = pure r
>
> pretraverseM t (f <*> x) = pretraverseM t f <*> pretraverseM t x
-}
pretraverseM :: Monad m => Traversal' a b -> FoldM m b r -> FoldM m a r
pretraverseM k (FoldM step begin done) = FoldM step' begin done
  where
    step' = flip (appEndoM . getConstant . k (Constant . EndoM . flip step))
{-# INLINABLE pretraverseM #-}

{- $reexports
    @Control.Monad.Primitive@ re-exports the 'PrimMonad' type class

    @Data.Foldable@ re-exports the 'Foldable' type class

    @Data.Vector.Generic@ re-exports the 'Vector' type class
-}
