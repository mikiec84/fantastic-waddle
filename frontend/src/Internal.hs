module Internal
  ( (<$$)
  , (<$$>)
  , tshow
  ) where

import Data.Text (Text,pack)

(<$$) :: (Functor f, Functor g) => a -> f (g b) -> f (g a)
(<$$) a = fmap (a <$)

infixr 9 <$$

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = (fmap . fmap)

infixr 9 <$$>

tshow :: Show a => a -> Text
tshow = pack . show
