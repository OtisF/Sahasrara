-- |
-- Module      : Sahasrara.Plugins.Netrunner.Plugin
-- Description : A plugin for finding Netrunner cards from Discord.
-- License     : MIT
-- Maintainer  : github.com/distributive
-- Stability   : experimental
-- Portability : POSIX
--
-- Commands for interfacing with NetrunnerDB.
module Sahasrara.Plugins.Netrunner.Plugin (netrunnerPlugin) where

import Control.Monad.IO.Class
import Control.Monad.Trans.Reader (ask)
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text, intercalate, isInfixOf, pack, unpack)
import Data.Text.ICU.Replace (replaceAll)
import Data.Time.Calendar
import Data.Time.Clock
import Discord.Types
import Sahasrara.Internal.Handler.Command ()
import Sahasrara.Plugins.Netrunner.Command.BanList
import Sahasrara.Plugins.Netrunner.Command.Glossary (nrGlossary)
import Sahasrara.Plugins.Netrunner.Command.Help (helpPageRoots)
import Sahasrara.Plugins.Netrunner.Command.Rules hiding (title)
import Sahasrara.Plugins.Netrunner.Command.Search
import Sahasrara.Plugins.Netrunner.Type.BanList (BanList (active), CardBan (..))
import qualified Sahasrara.Plugins.Netrunner.Type.BanList as BanList
import Sahasrara.Plugins.Netrunner.Type.Blacklist (Blacklist (..))
import Sahasrara.Plugins.Netrunner.Type.Card (Card (code, flavour, packCode, text, title))
import Sahasrara.Plugins.Netrunner.Type.Cycle (Cycle)
import qualified Sahasrara.Plugins.Netrunner.Type.Cycle as C
import Sahasrara.Plugins.Netrunner.Type.NrApi (NrApi (..))
import Sahasrara.Plugins.Netrunner.Type.Pack (Pack)
import qualified Sahasrara.Plugins.Netrunner.Type.Pack as P
import Sahasrara.Plugins.Netrunner.Utility.BanList (activeBanList, latestBanListActive, toMwlStatus)
import Sahasrara.Plugins.Netrunner.Utility.Card (toPack)
import Sahasrara.Plugins.Netrunner.Utility.Embed
import Sahasrara.Plugins.Netrunner.Utility.Find
import Sahasrara.Plugins.Netrunner.Utility.Format (formatText)
import Sahasrara.Plugins.Netrunner.Utility.NrApi (getNrApi)
import Sahasrara.Plugins.Netrunner.Utility.Search
import Sahasrara.Utility
import Sahasrara.Utility.Discord (formatFromEmojiName, sendEmbedMessage, sendMessage)
import Sahasrara.Utility.Embed (addColour)
import Sahasrara.Utility.Exception (BotException (GenericException), embedError)
import Sahasrara.Utility.Parser (inlineCommandHelper, integer)
import Sahasrara.Utility.Random (chooseOne, chooseOneSeeded)
import Sahasrara.Utility.Search (FuzzyCosts (..), closestValue, closestValueWithCosts)
import Sahasrara.Utility.SmartParser (PComm (parseComm), RestOfInput (ROI))
import Sahasrara.Utility.Types ()
import Text.Megaparsec (anySingleBut, single, some, try, (<|>))
import Text.RawString.QQ (r)

-- | @nrInline@ searches for cards by name.
nrInline :: EnvInlineCommand NrApi
nrInline = inlineCommandHelper "[[" "]]" (cardParser ']') $ outputCard embedCard

-- | @nrInlineImg@ searches for a card and outputs an image of it.
nrInlineImg :: EnvInlineCommand NrApi
nrInlineImg = inlineCommandHelper "{{" "}}" (cardParser '}') $ outputCard embedCardImg

-- | @nrInlineFlavour@ searches for a card and outputs its flavour.
nrInlineFlavour :: EnvInlineCommand NrApi
nrInlineFlavour = inlineCommandHelper "<<" ">>" (cardParser '>') $ outputCard embedCardFlavour

-- | @nrInlineBanHistory@ searches for a card and outputs its legality history.
nrInlineBanHistory :: EnvInlineCommand NrApi
nrInlineBanHistory = inlineCommandHelper "((" "))" (cardParser ')') $ outputCard embedBanHistory

-- | @cardParser@ parses a card and an optional specified set.
cardParser :: Char -> Parser (Text, Either Int Text)
cardParser c = try withSetIndex <|> try withSet <|> withoutSet
  where
    withSetIndex :: Parser (Text, Either Int Text)
    withSetIndex = do
      card <- some $ anySingleBut '|'
      _ <- single '|'
      index <- integer
      return (pack card, Left index)
    withSet :: Parser (Text, Either Int Text)
    withSet = do
      card <- some $ anySingleBut '|'
      _ <- single '|'
      set <- some $ anySingleBut c
      return (pack card, Right $ pack set)
    withoutSet :: Parser (Text, Either Int Text)
    withoutSet = do
      card <- some $ anySingleBut c
      return (pack card, Left (-1))

-- | @outputCard@ takes a function that displays a card in some form (e.g. by
-- displaying its text or art) and generates a function that applies the display
-- function to a given search query and outputs the result or errors if the
-- query is invalid.
-- Errors are embedded manually as errors thrown in inline commands are hidden.
outputCard :: (Card -> Message -> EnvDatabaseDiscord NrApi ()) -> ((Text, Either Int Text) -> Message -> EnvDatabaseDiscord NrApi ())
outputCard outf = \(card, set) m -> do
  api <- ask
  let printings = queryPrintings api card
  case set of
    Left 0 -> outf (queryCard api card) m
    Left index ->
      let i = if index < 0 then length printings + index else index
       in if i < 0 || i >= length printings
            then sendEmbedMessage m "" $ errorIndex index $ fromMaybe "?" $ title $ head printings
            else outf (printings !! i) m
    Right set' ->
      let mSet = matchedSet api set'
       in case find (setFilter mSet) printings of
            Just card' -> outf card' m
            Nothing -> case mSet of
              Left p -> sendEmbedMessage m "" $ errorNotFound (P.name p) $ fromMaybe "?" $ title $ head printings
              Right c -> sendEmbedMessage m "" $ errorNotFound (C.name c) $ fromMaybe "?" $ title $ head printings
  where
    setFilter :: Either Pack Cycle -> (Card -> Bool)
    setFilter (Left p) = (\card -> packCode card == (Just $ P.code p))
    setFilter (Right c) = (\card -> packCode card == (Just $ C.code c))
    matchedSet :: NrApi -> Text -> Either Pack Cycle
    matchedSet api set =
      case (matchedPack, matchedCycle, closestSet) of
        (Just p, _, _) -> Left p
        (_, Just c, _) -> Right c
        (_, _, fuzzyMatch) -> fuzzyMatch
      where
        matchedPack :: Maybe Pack
        matchedPack = find (\p -> standardise (P.code p) == standardise set) $ packs api
        matchedCycle :: Maybe Cycle
        matchedCycle = find (\c -> standardise (C.code c) == standardise set) $ cycles api
        closestSet :: Either Pack Cycle
        closestSet =
          let ls = zip (unpack <$> P.name <$> packs api) (Left <$> packs api)
              rs = zip (unpack <$> C.name <$> cycles api) (Right <$> cycles api)
           in closestValueWithCosts editCosts (ls ++ rs) $ unpack $ standardise set
        editCosts :: FuzzyCosts
        editCosts =
          FuzzyCosts
            { deletion = 1,
              insertion = 0,
              substitution = 1,
              transposition = 1
            }
    errorNotFound :: Text -> Text -> Embed
    errorNotFound set card = embedError $ GenericException "Set does not contain card" $ "`" <> (unpack set) <> "` does not contain *" <> unpack card <> "*."
    errorIndex :: Int -> Text -> Embed
    errorIndex index card = embedError $ GenericException "Invalid index" $ "`" <> show index <> "` is out of range.\nTry `sets " <> unpack card <> "` to see how many sets it was printed in."

-- | @nrSearch@ searches the card database with specific queries.
nrSearch :: EnvCommand NrApi
nrSearch = Command "search" searchPars []
  where
    searchPars :: Parser (Message -> EnvDatabaseDiscord NrApi ())
    searchPars = queryParser $ \cs pairs m -> do
      case cs of
        Nothing -> sendMessage m "No criteria provided!"
        Just [] -> sendMessage m $ "No cards found for `" <> pairsToNrdb pairs <> "`"
        Just [card] -> embedCard card m
        Just cards ->
          embedCards
            ("Query: `" <> pairsToNrdb pairs <> "`\n")
            cards
            ("_[...view on NRDB](" <> pairsToQuery pairs <> ")_")
            ("_[..." <> pack (show $ length cards - 10) <> " more](" <> pairsToQuery pairs <> ")_")
            m

-- | @nrRandom@ searches the card database with specific queries and outputs a
-- single result at random.
nrRandom :: EnvCommand NrApi
nrRandom = Command "random" randomPars []
  where
    randomPars :: Parser (Message -> EnvDatabaseDiscord NrApi ())
    randomPars = queryParser $ \cs pairs m -> do
      case cs of
        Nothing -> do
          api <- ask
          card <- liftIO $ chooseOne $ cards api
          embedCard card m
        Just [] -> sendMessage m $ "No cards found for `" <> pairsToNrdb pairs <> "`"
        Just cards -> do
          card <- liftIO $ chooseOne cards
          embedCard card m

-- | @nrHoroscope@ gets a random piece of flavour text from the card pool,
-- seeded by the current date.
nrHoroscope :: EnvCommand NrApi
nrHoroscope = Command "horoscope" horoscopePars []
  where
    horoscopePars :: Parser (Message -> EnvDatabaseDiscord NrApi ())
    horoscopePars = return $ \m -> do
      api <- ask
      let fs = filterFlavours (blacklist api) (cards api)
      seed <- liftIO $ getCurrentTime >>= return . fromIntegral . toModifiedJulianDay . utctDay
      f <- liftIO $ chooseOneSeeded seed fs
      f' <- formatText f
      sendEmbedMessage m "" $ addColour (RGB 170 141 216) $ embedText ":crystal_ball: Horoscope :crystal_ball:" $ replaceAll [r|"(.*?)"[.\S\s]*|] "$1" f'
    filterFlavours :: Blacklist -> [Card] -> [Text]
    filterFlavours Blacklist {badSubstrings = badSubstrings, badCards = badCards} cards =
      let flavoured = filter ((Nothing /=) . flavour) cards
          withoutBadCards = filter (\c -> all (\b -> Just b /= title c) badCards) flavoured
       in filter (\c -> not $ any (`isInfixOf` c) badSubstrings) $ mapMaybe flavour withoutBadCards -- Without bad substrings

-- | @nrBanList@ is a command listing all cards affected by a banlist.
nrBanList :: EnvCommand NrApi
nrBanList = Command "banlist" (parseComm banListComm) []
  where
    banListComm ::
      Either () (RestOfInput Text) ->
      Message ->
      EnvDatabaseDiscord NrApi ()
    banListComm (Left ()) = embedBanLists
    banListComm (Right (ROI q)) = sendEmbed q
    sendEmbed :: Text -> Message -> EnvDatabaseDiscord NrApi ()
    sendEmbed query m = do
      api <- ask
      embedBanList (queryBanList api query) m

-- | @nrRules@ is a command that fetches Netrunner rulings.
nrRules :: EnvCommand NrApi
nrRules = Command "rules" (parseComm rulesComm) []
  where
    rulesComm :: RestOfInput Text -> Message -> EnvDatabaseDiscord NrApi ()
    rulesComm (ROI q) m = do
      let (rTitle, rBody, colour) = case getRuling q of
            Left (Ruling t b) -> (t, b, Red)
            Right (Ruling t b) -> (t, b, Blue)
      sendEmbedMessage m "" $ addColour colour $ embedText rTitle rBody

-- | @nrSets@ is a command that lists all packs a card was printed in.
nrSets :: EnvCommand NrApi
nrSets = Command "sets" (parseComm setsComm) []
  where
    setsComm :: RestOfInput Text -> Message -> EnvDatabaseDiscord NrApi ()
    setsComm (ROI card) m = case card of
      "" -> embedSets m
      _ -> embedCardSets card m

-- | @nrCycles@ is a command that lists the packs in a cycle
nrCycles :: EnvCommand NrApi
nrCycles = Command "cycles" (parseComm cyclesComm) []
  where
    cyclesComm :: RestOfInput Text -> Message -> EnvDatabaseDiscord NrApi ()
    cyclesComm (ROI cy) m = case cy of
      "" -> embedCycles m
      c -> do
        api <- ask
        let pairs = zip (map (unpack . standardise . C.name) $ cycles api) (cycles api)
            closestCycle = closestValue pairs $ unpack $ standardise c
            title = ":recycle: **" <> C.name closestCycle <> "** :recycle:"
            url = "https://netrunnerdb.com/en/cycle/" <> C.code closestCycle
            pre = if C.rotated closestCycle then "**Rotated**" else ""
        embedSetsOn title url pre (\c' -> c' == closestCycle) m

-- | @embedCard@ takes a card and embeds it in a message.
embedCard :: Card -> Message -> EnvDatabaseDiscord NrApi ()
embedCard card m = do
  api <- ask
  sendEmbedMessage m "" =<< cardToEmbed api card

-- | @embedCards@ takes a list of cards and embeds their names.
embedCards :: Text -> [Card] -> Text -> Text -> Message -> EnvDatabaseDiscord NrApi ()
embedCards pre cards post err m = do
  api <- ask
  sendEmbedMessage m "" =<< cardsToEmbed api pre cards post err

-- | @embedCardImg@ embeds a card's image in a message, if able.
embedCardImg :: Card -> Message -> EnvDatabaseDiscord NrApi ()
embedCardImg card m = do
  api <- ask
  sendEmbedMessage m "" $ cardToImgEmbed api card

-- | @embedCardFlavour@ embeds a card's flavour in a message, if able.
embedCardFlavour :: Card -> Message -> EnvDatabaseDiscord NrApi ()
embedCardFlavour card m = do
  api <- ask
  let card' = case code card of
        Just "07024" -> queryCard api "Déjà Vu"
        Just "01002" -> queryCard api "The Twins"
        _ -> card
  cText <- formatText $ fromMaybe "" $ text card'
  embed <- case code card' of
    Just "12077" -> cardToEmbedWithText api card' cText
    _ -> cardToFlavourEmbed api card'
  sendEmbedMessage m "" embed

-- | @embedCardSets@ embeds a list of packs a card was printed in.
embedCardSets :: Text -> Message -> EnvDatabaseDiscord NrApi ()
embedCardSets card m = do
  api <- ask
  let printings = queryPrintings api card
      sets = mapMaybe (toPack api) printings
      entries = map (\s -> "`" <> P.code s <> "` - " <> P.name s) sets
  embed <- cardToEmbedWithText api (head printings) $ intercalate "\n" entries
  sendEmbedMessage m "" embed

-- | @embedSets@ embeds all sets from Netrunner history.
embedSets :: Message -> EnvDatabaseDiscord NrApi ()
embedSets =
  let title = ":card_box: All Netrunner sets :card_box:"
      url = "https://netrunnerdb.com/en/sets"
      pre = ":white_check_mark: legal | :repeat: rotated | :no_entry_sign: never legal in standard"
   in embedSetsOn title url pre (\_ -> True)

-- | @embedSetsOn@ embeds all sets from Netrunner history that fulfil a predicate.
embedSetsOn :: Text -> Text -> Text -> (Cycle -> Bool) -> Message -> EnvDatabaseDiscord NrApi ()
embedSetsOn title url pre predicate m = do
  api <- ask
  sep <- formatFromEmojiName "s_subroutine"
  let cols = mapMaybe (formatCycle api $ sep <> " ") $ filter predicate $ cycles api
      ordered = filter isCycle cols ++ filter (not . isCycle) cols
  sendEmbedMessage m "" $ addColour Blue $ embedColumnsWithUrl title url pre ordered
  where
    formatCycle :: NrApi -> Text -> Cycle -> Maybe (Text, [Text])
    formatCycle NrApi {packs = packs} sep c =
      case filter (\p -> P.cycleCode p == C.code c) packs of
        [] -> Nothing
        ps -> Just (cycleName c, map ((sep <>) . P.name) ps)
    cycleName :: Cycle -> Text
    cycleName c =
      (if isSpecial c then ":no_entry_sign: " else if C.rotated c then ":repeat: " else ":white_check_mark: ")
        <> C.name c
    isSpecial :: Cycle -> Bool
    isSpecial c = case C.code c of
      "draft" -> True
      "napd" -> True
      _ -> False
    isCycle :: (Text, [Text]) -> Bool
    isCycle (_, xs) = length xs > 2

-- | @embedCycles@ embeds the name of each Netrunner cycle.
embedCycles :: Message -> EnvDatabaseDiscord NrApi ()
embedCycles m = do
  api <- ask
  let title = ":recycle: All Netrunner cycles :recycle:"
      url = "https://netrunnerdb.com/en/sets"
      pre = ":white_check_mark: legal | :repeat: rotated"
      list = intercalate "\n" $ map formatCycle $ filter (isCycle api) $ cycles api
      text = pre <> "\n\n" <> list
  sendEmbedMessage m "" $ addColour Blue $ embedTextWithUrl title url text
  where
    formatCycle :: Cycle -> Text
    formatCycle c = (if C.rotated c then ":repeat: " else ":white_check_mark: ") <> C.name c
    isCycle :: NrApi -> Cycle -> Bool
    isCycle NrApi {packs = packs} c =
      let count = length $ filter (\p -> P.cycleCode p == C.code c) packs
       in count > 2

-- | @embedBanHistory@ embeds a card's banlist history.
embedBanHistory :: Card -> Message -> EnvDatabaseDiscord NrApi ()
embedBanHistory card m = do
  api <- ask
  embed <- cardToEmbedWithText api card $ listBanHistory api card
  let colour = case toMwlStatus api (activeBanList api) card of
        Banned -> Red
        Legal -> Green
        _ -> Yellow
  sendEmbedMessage m "" $ addColour colour embed

-- | @embedBanLists@ embeds all banlists in Netrunner history.
embedBanLists :: Message -> EnvDatabaseDiscord NrApi ()
embedBanLists m = do
  api <- ask
  let embed = embedTextWithUrl "Standard Banlists" "https://netrunnerdb.com/en/banlists" $ listBanLists api
      colour = if latestBanListActive api then Red else Yellow
  sendEmbedMessage m "" $ addColour colour embed

-- | @embedBanList@ embeds the list of cards affected by a given banlist.
embedBanList :: BanList -> Message -> EnvDatabaseDiscord NrApi ()
embedBanList banList m = do
  api <- ask
  let (pre, cCards, rCards) = listAffectedCards api banList
      header = BanList.name banList <> if active banList then " (active)" else ""
      colour = if active banList then Red else Yellow
  sendEmbedMessage m "" $ addColour colour $ embedColumns header pre [("Corp Cards", cCards), ("Runner Cards", rCards)]

-- | @netrunnerStartUp@ loads the NetrunnerDB api once at start up
netrunnerStartUp :: StartUp NrApi
netrunnerStartUp = StartUp $ liftIO getNrApi

-- | @welcomePlugin@ assembles these commands into a plugin.
netrunnerPlugin :: EnvPlugin NrApi
netrunnerPlugin =
  (envPlug "netrunner" netrunnerStartUp)
    { commands =
        [ nrSearch,
          nrRandom,
          nrSets,
          nrCycles,
          nrBanList,
          commandAlias "bl" nrBanList,
          commandAlias "mwl" nrBanList,
          nrRules,
          commandAlias "cr" nrRules,
          nrGlossary,
          commandAlias "g" nrGlossary,
          nrHoroscope
        ],
      inlineCommands = [nrInline, nrInlineImg, nrInlineFlavour, nrInlineBanHistory],
      helpPages = helpPageRoots
    }
