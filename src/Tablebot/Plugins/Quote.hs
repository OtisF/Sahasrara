-- |
-- Module      : Tablebot.Plugins.Quote
-- Description : A more complex example using databases.
-- Copyright   : (c) Finnbar Keating 2021
-- License     : MIT
-- Maintainer  : finnjkeating@gmail.com
-- Stability   : experimental
-- Portability : POSIX
--
-- This is an example plugin which allows user to @!quote add@ their favourite
-- quotes and then @!quote show n@ a particular quote.
module Tablebot.Plugins.Quote
  ( quotePlugin,
  )
where

import Data.Text (append, pack)
import Database.Persist
import Database.Persist.Sqlite
import Database.Persist.TH
import GHC.Int (Int64)
import Tablebot.Plugin
import Tablebot.Plugin.Discord (Message, sendMessageVoid)
import Tablebot.Plugin.Parser (number, quoted, sp, untilEnd1)
import Text.Megaparsec

-- Our Quote table in the database. This is fairly standard for Persistent,
-- however you should note the name of the migration made.
share
  [mkPersist sqlSettings, mkMigrate "quoteMigration"]
  [persistLowerCase|
Quote
    quote String
    author String
    deriving Show
|]

-- | Our quote command, which combines @addQuote@ and @showQuote@.
quote :: Command
quote =
  Command
    "quote"
    ( ((try (chunk "add") *> addQuote) <|> (try (chunk "show") *> showQuote))
        <?> "Unknown quote functionality."
    )

-- | @addQuote@, which looks for a message of the form
-- @!quote add "quoted text" - author@, and then stores said quote in the
-- database, returning the ID used.
addQuote :: Parser (Message -> DatabaseDiscord ())
addQuote = do
  sp
  quote <- try quoted <?> error ++ " (needed a quote)"
  sp
  single '-' <?> error ++ " (needed hyphen)"
  sp
  addQ quote <$> untilEnd1 <?> error ++ " (needed author)"
  where
    addQ :: String -> String -> Message -> DatabaseDiscord ()
    addQ quote author m = do
      added <- insert $ Quote quote author
      let res = pack $ show $ fromSqlKey added
      sendMessageVoid m ("Quote added as #" `append` res)
    error = "Syntax is: .quote add \"quote\" - author"

-- | @showQuote@, which looks for a message of the form @!quote show n@, looks
-- that quote up in the database and responds with that quote.
showQuote :: Parser (Message -> DatabaseDiscord ())
showQuote = do
  sp
  num <- number <?> error
  let id = fromIntegral num :: Int64
  return $ showQ id
  where
    showQ :: Int64 -> Message -> DatabaseDiscord ()
    showQ id m = do
      qu <- get $ toSqlKey id
      case qu of
        Just (Quote txt author) ->
          sendMessageVoid m $ pack $ txt ++ " - " ++ author
        Nothing -> sendMessageVoid m "Couldn't get that quote!"
    error = "Syntax is: .quote show n"

showQuoteHelp :: HelpPage
showQuoteHelp = HelpPage "show" "show a quote by number" "**Show Quote**\nShows a quote by id\n\n*Usage:* `quote show <id>`" []

addQuoteHelp :: HelpPage
addQuoteHelp = HelpPage "add" "add a new quote" "**Add Quote**\nAdds a quote\n\n*Usage:* `quote add \"quote\" - author`" []

quoteHelp :: HelpPage
quoteHelp = HelpPage "quote" "store and retrieve quotes" "**Quotes**\nAllows storing and retrieving quotes" [showQuoteHelp, addQuoteHelp]

-- | @quotePlugin@ assembles the @quote@ command (consisting of @add@ and
-- @show@) and the database migration into a plugin.
quotePlugin :: Plugin
quotePlugin = plug {commands = [quote], migrations = [quoteMigration], helpPages = [quoteHelp]}
