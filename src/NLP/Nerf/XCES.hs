{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}


-- | Support for the XCES format.


module NLP.Nerf.XCES
( nerXCES
) where


import qualified Data.Text.Lazy as L
import           Data.List (intercalate, intersperse)
import           Data.Char (isSpace)
import           Text.HTML.TagSoup ((~==))
import qualified Text.HTML.TagSoup as S
import           Text.XML.PolySoup hiding (Parser)

import           Data.Named.Tree
import           NLP.Nerf.Types
import qualified NLP.Nerf.Tokenize as Tok


---------------------------------------------------------------------
-- Core types
---------------------------------------------------------------------


-- | An XML tag.
type Tag = S.Tag L.Text


-- | An XML parser.
type Parser a = XmlParser L.Text a


---------------------------------------------------------------------
-- XML tags
---------------------------------------------------------------------


-- | A sentence opening tag.
sentOpen :: Tag
sentOpen = S.TagOpen "chunk" [("type", "s")]


-- | A sentence opening tag.
sentClose :: Tag
sentClose = S.TagClose "chunk"


-- | A sentence opening tag.
tokOpen :: Tag
tokOpen = S.TagOpen "tok" []


-- -- | A sentence opening tag.
-- tokClose :: Tag
-- tokClose = S.TagClose "tok"


-- | A sentence opening tag.
nsOpen :: Tag
nsOpen = S.TagOpen "ns" []


---------------------------------------------------------------------
-- XML chunking
---------------------------------------------------------------------


-- | Group tags corresponding to individual sentences as right elements.
chunk :: [Tag] -> [Either Tag [Tag]]
chunk (x:xs)
    | x ~== sentOpen =
        let (sent, rest) = takeSent xs
        in  Right (x:sent) : chunk rest
    | otherwise = Left x : chunk xs
chunk [] = []


-- | Take tags starting with a sentence.
takeSent :: [Tag] -> ([Tag], [Tag])
takeSent = go [] where
    go acc (x:xs)
        | x == sentClose    = (reverse $ x:acc, xs)
        | otherwise         = go (x:acc) xs
    go _ []                 = error "takeSent: expected sentence closing tag"


-- | Remove division into chunks.
unChunk :: [Either Tag [Tag]] -> [Tag]
unChunk = concatMap $ either (:[]) id


---------------------------------------------------------------------
-- XML sentence intermediate
---------------------------------------------------------------------


-- | Intermediate sentence representation.  The ending tag is not preserved
-- since it is always the same.  It should be remembered during the sentence
-- rendering process.
data SentI = SentI {
    -- | Beginning tag.
      sentBegI  :: Tag
    -- | Sentence contents.
    , sentConI  :: [(SegT, XmlTree)]
    } deriving (Show)


-- | Type of a sentence sub-element.
data SegT = TokT | NsT | OtherT deriving (Show)


-- | Identify type of a sub-tree.
idTreeT :: XmlTree -> SegT
idTreeT (Node x _)
    | x ~== tokOpen = TokT
    | x ~== nsOpen  = NsT
    | otherwise     = OtherT


-- | XML intermediate sentence parser.
sentIP :: Parser SentI
sentIP =
    begP >^> \x -> SentI x <$> many elemP
  where
    begP = tag "chunk" *> hasAttr "type" "s" *> getTag
    elemP = (\x -> (idTreeT x, x)) <$> xmlTreeP


---------------------------------------------------------------------
-- XML sentence
---------------------------------------------------------------------


-- | An XML sentence.  The ending tag is not preserved since it is always
-- the same.  It should be remembered during the sentence rendering process.
data Sent t = Sent {
    -- | Beginning tag of a sentence.
      sentBeg   :: Tag
    -- | Contents of a sentence.
    , sentCon   :: t Tok
    -- | Additional, non-token tags, placed after the last token
    , sentAdd   :: [XmlTree] }


-- | Translate sentence into its final representation.
joinSent :: SentI -> Sent []
joinSent SentI{..} =
    uncurry (Sent sentBegI) (go [] [] False sentConI)
  where
    -- TODO: could we represent this function as a fold?
    go acc res hasNs ((typ, tagTree) : xs) = case typ of
        TokT ->
            let tok = Tok
                    { orth   = tagsParseXml tokOrthP (enumTree tagTree)
                    , nps    = hasNs
                    , tagsIn = tagTree
                    , tagsBf = reverse acc }
            in  go [] (tok:res) False xs
        NsT    -> go (tagTree:acc) res True xs
        OtherT -> go (tagTree:acc) res hasNs xs
    go acc res _ [] = (reverse res, reverse acc)


-- | Parse a list of tags into a sentence.
parseSent :: [Tag] -> Sent []
parseSent = joinSent . tagsParseXml sentIP


---------------------------------------------------------------------
-- Annotated XML sentence
---------------------------------------------------------------------


-- | List of a elements annotated with NEs.
newtype Ann a = Ann { unAnn :: NeForest NE a }


-- | A sentence opening tag.
neOpen :: NE -> Tag
neOpen x = S.TagOpen "group" [("type", L.fromStrict x)]


-- | A sentence opening tag.
neClose :: Tag
neClose = S.TagClose "group"


-- | Render an annotated sentence.
renderAnnSent :: Sent Ann -> [Tag]
renderAnnSent Sent{..} = between
    [sentBeg, newline]
    [newline, sentClose]
        ( interMap renderNeTree (unAnn sentCon) )
        -- TODO: ponizej nie intersperse, trzeba dodac newline
        -- przed kazdym elementem.
        -- ++ intersperse newline (concatMap enumTree sentAdd) )


-- | Render an element of an annotated sentence.
renderNeTree :: NeTree NE Tok -> [Tag]
renderNeTree (Node (Left v) xs)
    = between
        [neOpen v, newline]
        [newline, neClose]
    $ interMap renderNeTree xs
renderNeTree (Node (Right t) _) = renderTok t


---------------------------------------------------------------------
-- XML Token
---------------------------------------------------------------------


-- | An XML token.
data Tok = Tok
    { orth      :: L.Text    -- ^ Orthographic form
    , nps       :: Bool      -- ^ No preceding space
    , tagsIn    :: XmlTree   -- ^ Token tags
    , tagsBf    :: [XmlTree] -- ^ Non-token tags before the token
    }


instance Tok.Word Tok where
    word = Tok.word . orth


tokOrthP :: Parser L.Text
tokOrthP = maybe "" id <$> (tag "tok" ^> findIgnore (tag "orth" ^> text))


-- | Render token.
renderTok :: Tok -> [Tag]
renderTok Tok{..} = case before of
    []  -> inside
    _   -> intercalate [newline] [before, inside]
  where
    before = interMap enumTree tagsBf
    inside =
        let Node v xs = tagsIn
        in  between [v, newline] [newline, endFrom v]
                (interMap enumTree xs)
            
    


---------------------------------------------------------------------
-- XML generic
---------------------------------------------------------------------


-- | A parsed XML tree.  In nodes the content/opening tags are preserved.
type XmlTree = Tree Tag


-- | Parse tags to an XML tree representation.
xmlTreeP :: Parser XmlTree
xmlTreeP =
    let commTag = satisfyPred ((,) <$> getTag <*> isTagComment)
        textTag = satisfyPred ((,) <$> getTag <*> isTagText)
        leafTag = fst <$> (textTag <|> commTag)
    in  trueXmlTreeP <|> (Node <$> leafTag <*> pure [])


trueXmlTreeP :: Parser XmlTree
trueXmlTreeP = do
    (beg, name) <- satisfyPred ((,) <$> getTag <*> tagOpenName)
    subForest <- beg `seq` name `seq` many xmlTreeP
    satisfyPred $ isTagCloseName name
    return $ Node beg subForest


-- | Enumerate tags present in the tree.
enumTree :: XmlTree -> [Tag]
enumTree (Node v xs) = if S.isTagOpen v
    then v : concatMap enumTree xs ++ [endFrom v]
    else [v]


---------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------


-- | Put the list between the two elements.
between :: [a] -> [a] -> [a] -> [a]
between p q xs = p ++ xs ++ q


-- | A newline tag.
newline :: Tag
newline = S.TagText "\n"


-- | Make closing tag from the opening tag.
endFrom :: Tag -> Tag
endFrom (S.TagOpen x _) = S.TagClose x
endFrom _               = error "endFrom: not an opening tag"


-- | Map and intercalate with newlines.
interMap :: (a -> [Tag]) -> [a] -> [Tag]
interMap f = intercalate [newline] . map f


---------------------------------------------------------------------
-- NER
---------------------------------------------------------------------


-- | Annotate XCES (in a form of a tag list) with NEs with respect
-- to the given NER function.
-- nerXCES :: Nerf.Nerf -> L.Text -> L.Text
nerXCES :: (String -> NeForest NE Word) -> L.Text -> L.Text
nerXCES nerFun
    = S.renderTagsOptions opts
    . unChunk
    . intersperse (Left newline)
    . mapR
        ( renderAnnSent
        . nerSent nerFun
        . parseSent )
    . chunk
    . filter relevant
    . S.parseTags
  where
    opts = S.renderOptions {S.optMinimize = const True}
    mapR = map . fmap
    relevant (S.TagWarning _)       = False
    relevant (S.TagPosition _ _)    = False
    relevant (S.TagText x)          = not $ L.all isSpace x
    relevant _                      = True


-- | Annotate XCES sentence with NEs.
-- nerSent :: Nerf.Nerf -> Sent [] -> Sent Ann
nerSent :: (String -> NeForest NE Word) -> Sent [] -> Sent Ann
nerSent nerFun s@Sent{..} = s
    { sentCon = Ann $ Tok.sync
        (nerFun $ restoreOrigSent sentCon)
        sentCon }


-- | Restore original sentence.
restoreOrigSent :: [Tok] -> String
restoreOrigSent
    = dropWhile isSpace
    . concatMap tokStr
  where
    tokStr Tok{..} = (if nps then "" else " ") ++ (L.unpack orth)
