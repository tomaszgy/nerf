-- | Basic Nerf types.


module NLP.Nerf.Types
( Orth
, Word (..)
, NE
, Ob
, Lb
) where


import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Named.IOB as IOB


-- | An orthographic form.
type Orth = T.Text


-- | A morphosyntactic segment.
data Word = Word {
    -- | An orthographic form,
      orth  :: Orth
    -- | No preceding space.
    , nps   :: Bool
    -- | Morphosyntactic description.
    -- TODO: Use the tagset-positional package?
    , msd   :: [T.Text] }
    deriving (Show)


-- | A named entity.  It has a complex structure for the sake of flexibility.
-- In particular, the following type can be used both to represent simplex
-- labels as well as NE lables consisting of several elements (main type,
-- subtype, derivation type and so on, as in TEI NKJP).
type NE = M.Map T.Text T.Text
-- type NE = T.Text


-- | An observation consist of an index (of list type) and an actual
-- observation value.
type Ob = ([Int], T.Text)


-- | A label is created by encoding the named entity forest using the
-- IOB method.
type Lb = IOB.Label NE
