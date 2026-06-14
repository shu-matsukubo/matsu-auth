{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode, object, (.=))
import qualified Data.Base64.Types as B64Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64Url
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Pool (Pool, createPool, withResource)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.UUID.V4 (nextRandom)
import Database.PostgreSQL.Simple
  ( Connection,
    Only (Only),
    close,
    connectPostgreSQL,
    execute,
    query,
  )
import GHC.Generics (Generic)
import Network.HTTP.Types (hContentType)
import Network.Wai (Middleware)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Servant
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (hClose)
import System.Process
  ( CreateProcess (std_err, std_in, std_out),
    StdStream (CreatePipe),
    proc,
    waitForProcess,
    withCreateProcess,
  )
import qualified Crypto.BCrypt as BCrypt

type API =
  "health" :> Get '[JSON] HealthResponse
    :<|> "auth" :> "register" :> ReqBody '[JSON] AuthRequest :> Post '[JSON] TokenResponse
    :<|> "auth" :> "login" :> ReqBody '[JSON] AuthRequest :> Post '[JSON] TokenResponse
    :<|> "auth" :> "refresh" :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] TokenResponse
    :<|> ".well-known" :> "jwks.json" :> Get '[JSON] Value

data AppEnv = AppEnv
  { envPool :: Pool Connection,
    envIssuer :: Text,
    envAudience :: Text,
    envAccessTokenTtl :: NominalDiffTime,
    envRefreshTokenTtl :: NominalDiffTime,
    envPrivateKeyPath :: FilePath,
    envJwks :: Value,
    envKeyId :: Text
  }

data AuthRequest = AuthRequest
  { email :: Text,
    password :: Text
  }
  deriving (Generic, Show)

instance FromJSON AuthRequest

data RefreshRequest = RefreshRequest
  { refreshToken :: Text
  }
  deriving (Generic, Show)

instance FromJSON RefreshRequest

data TokenResponse = TokenResponse
  { accessToken :: Text,
    refreshToken :: Text,
    tokenType :: Text,
    expiresIn :: Int
  }
  deriving (Generic, Show)

instance ToJSON TokenResponse

data HealthResponse = HealthResponse
  { status :: Text
  }
  deriving (Generic, Show)

instance ToJSON HealthResponse

data UserRecord = UserRecord
  { userSub :: UUID,
    userEmail :: Text,
    userPasswordHash :: Text
  }

main :: IO ()
main = do
  port <- readEnv "AUTH_PORT" 8080
  databaseUrl <- textEnv "AUTH_DATABASE_URL" "postgres://matsu-auth:matsu-auth-pass@localhost:15432/matsu-auth"
  issuer <- textEnv "AUTH_ISSUER" "http://localhost:18081"
  audience <- textEnv "AUTH_AUDIENCE" "matsu-api"
  accessTtl <- fromInteger <$> readEnv "AUTH_ACCESS_TOKEN_TTL_SECONDS" 900
  refreshTtl <- fromInteger <$> readEnv "AUTH_REFRESH_TOKEN_TTL_SECONDS" 2592000
  privateKeyPath <- stringEnv "AUTH_PRIVATE_KEY_PATH" "keys/private.pem"
  jwksPath <- stringEnv "AUTH_JWKS_PATH" "keys/jwks.json"
  keyId <- textEnv "AUTH_KEY_ID" "matsu-dev-key-1"
  allowedOrigin <- textEnv "AUTH_ALLOWED_ORIGIN" "http://localhost:5173"
  jwksBytes <- BL.readFile jwksPath
  jwks <- either fail pure (eitherDecode jwksBytes)
  pool <- createPool (connectPostgreSQL (TE.encodeUtf8 databaseUrl)) close 1 10 10
  let env = AppEnv pool issuer audience accessTtl refreshTtl privateKeyPath jwks keyId
  putStrLn ("matsu auth listening on :" <> show port)
  run port (corsMiddleware allowedOrigin (serve (Proxy :: Proxy API) (server env)))

server :: AppEnv -> Server API
server env =
  pure (HealthResponse "ok")
    :<|> registerHandler env
    :<|> loginHandler env
    :<|> refreshHandler env
    :<|> pure (envJwks env)

registerHandler :: AppEnv -> AuthRequest -> Handler TokenResponse
registerHandler env req = do
  validateAuthRequest req
  maybeExisting <- liftIO $ findUserByEmail env (email req)
  case maybeExisting of
    Just _ -> throwError err409 {errBody = "email already registered"}
    Nothing -> do
      sub <- liftIO nextRandom
      hash <- liftIO $ hashPassword (password req)
      _ <- liftIO $ insertUser env sub (email req) hash
      issueTokens env sub (email req)

loginHandler :: AppEnv -> AuthRequest -> Handler TokenResponse
loginHandler env req = do
  validateAuthRequest req
  maybeUser <- liftIO $ findUserByEmail env (email req)
  case maybeUser of
    Nothing -> throwError err401 {errBody = "invalid credentials"}
    Just user -> do
      let ok = BCrypt.validatePassword (TE.encodeUtf8 (userPasswordHash user)) (TE.encodeUtf8 (password req))
      if ok
        then issueTokens env (userSub user) (userEmail user)
        else throwError err401 {errBody = "invalid credentials"}

refreshHandler :: AppEnv -> RefreshRequest -> Handler TokenResponse
refreshHandler env (RefreshRequest token) = do
  maybeUser <- liftIO $ findUserByRefreshToken env token
  case maybeUser of
    Nothing -> throwError err401 {errBody = "invalid refresh token"}
    Just user -> do
      _ <- liftIO $ revokeRefreshToken env token
      issueTokens env (userSub user) (userEmail user)

validateAuthRequest :: AuthRequest -> Handler ()
validateAuthRequest req
  | T.length (password req) < 8 = throwError err400 {errBody = "password must be at least 8 characters"}
  | not ("@" `T.isInfixOf` email req) = throwError err400 {errBody = "email is invalid"}
  | otherwise = pure ()

hashPassword :: Text -> IO Text
hashPassword raw = do
  maybeHash <- BCrypt.hashPasswordUsingPolicy BCrypt.slowerBcryptHashingPolicy (TE.encodeUtf8 raw)
  case maybeHash of
    Nothing -> fail "failed to hash password"
    Just hashed -> pure (TE.decodeUtf8 hashed)

issueTokens :: AppEnv -> UUID -> Text -> Handler TokenResponse
issueTokens env sub emailAddress = do
  now <- liftIO getCurrentTime
  access <- liftIO $ makeAccessToken env now sub emailAddress
  refresh <- liftIO nextRandom
  let refreshText = UUID.toText refresh
  _ <- liftIO $ insertRefreshToken env refreshText sub (addUTCTime (envRefreshTokenTtl env) now)
  pure
    TokenResponse
      { accessToken = access,
        refreshToken = refreshText,
        tokenType = "Bearer",
        expiresIn = floor (envAccessTokenTtl env)
      }

makeAccessToken :: AppEnv -> UTCTime -> UUID -> Text -> IO Text
makeAccessToken env now sub emailAddress = do
  let iat = floor (utcTimeToPOSIXSeconds now) :: Int
      expTime = floor (utcTimeToPOSIXSeconds (addUTCTime (envAccessTokenTtl env) now)) :: Int
      header =
        object
          [ "alg" .= ("RS256" :: Text),
            "typ" .= ("JWT" :: Text),
            "kid" .= envKeyId env
          ]
      payload =
        object
          [ "iss" .= envIssuer env,
            "aud" .= envAudience env,
            "sub" .= UUID.toText sub,
            "email" .= emailAddress,
            "token_use" .= ("access" :: Text),
            "iat" .= iat,
            "exp" .= expTime
          ]
      unsigned = b64Json header <> "." <> b64Json payload
  signature <- signRS256 (envPrivateKeyPath env) (TE.encodeUtf8 unsigned)
  pure (unsigned <> "." <> base64Url signature)

signRS256 :: FilePath -> BS.ByteString -> IO BS.ByteString
signRS256 privateKeyPath input =
  withCreateProcess opensslProcess $ \maybeIn maybeOut maybeErr processHandle -> do
    case (maybeIn, maybeOut, maybeErr) of
      (Just hin, Just hout, Just herr) -> do
        BS.hPut hin input
        hClose hin
        output <- BS.hGetContents hout
        errOutput <- BS.hGetContents herr
        exitCode <- waitForProcess processHandle
        case exitCode of
          ExitSuccess -> pure output
          _ -> fail ("openssl signing failed: " <> show errOutput)
      _ -> fail "failed to open openssl process handles"
  where
    opensslProcess =
      (proc "openssl" ["dgst", "-sha256", "-sign", privateKeyPath, "-binary"])
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe
        }

findUserByEmail :: AppEnv -> Text -> IO (Maybe UserRecord)
findUserByEmail env targetEmail =
  withResource (envPool env) $ \conn -> do
    rows <- query conn "SELECT sub, email, password_hash FROM users WHERE email = ?" (Only targetEmail)
    pure (rowToUser <$> firstMaybe rows)

findUserByRefreshToken :: AppEnv -> Text -> IO (Maybe UserRecord)
findUserByRefreshToken env token =
  withResource (envPool env) $ \conn -> do
    rows <-
      query
        conn
        "SELECT users.sub, users.email, users.password_hash FROM refresh_tokens INNER JOIN users ON users.sub = refresh_tokens.user_sub WHERE refresh_tokens.token = ? AND refresh_tokens.revoked_at IS NULL AND refresh_tokens.expires_at > now()"
        (Only token)
    pure (rowToUser <$> firstMaybe rows)

insertUser :: AppEnv -> UUID -> Text -> Text -> IO Int64
insertUser env sub emailAddress passwordHash =
  withResource (envPool env) $ \conn ->
    execute
      conn
      "INSERT INTO users (sub, email, password_hash) VALUES (?, ?, ?)"
      (sub, emailAddress, passwordHash)

insertRefreshToken :: AppEnv -> Text -> UUID -> UTCTime -> IO Int64
insertRefreshToken env token sub expiresAt =
  withResource (envPool env) $ \conn ->
    execute
      conn
      "INSERT INTO refresh_tokens (token, user_sub, expires_at) VALUES (?, ?, ?)"
      (token, sub, expiresAt)

revokeRefreshToken :: AppEnv -> Text -> IO Int64
revokeRefreshToken env token =
  withResource (envPool env) $ \conn ->
    execute conn "UPDATE refresh_tokens SET revoked_at = now() WHERE token = ?" (Only token)

rowToUser :: (UUID, Text, Text) -> UserRecord
rowToUser (sub, emailAddress, passwordHash) = UserRecord sub emailAddress passwordHash

firstMaybe :: [a] -> Maybe a
firstMaybe [] = Nothing
firstMaybe (x : _) = Just x

b64Json :: ToJSON a => a -> Text
b64Json = base64Url . BL.toStrict . encode

base64Url :: BS.ByteString -> Text
base64Url = B64Types.extractBase64 . B64Url.encodeBase64Unpadded

corsMiddleware :: Text -> Middleware
corsMiddleware allowedOrigin =
  cors $ \_ ->
    Just
      simpleCorsResourcePolicy
        { corsOrigins = Just ([TE.encodeUtf8 allowedOrigin], True),
          corsMethods = ["GET", "POST", "OPTIONS"],
          corsRequestHeaders = ["authorization", "content-type"],
          corsExposedHeaders = Just [hContentType]
        }

readEnv :: Read a => String -> a -> IO a
readEnv key fallback = maybe fallback read <$> lookupEnv key

textEnv :: String -> Text -> IO Text
textEnv key fallback = maybe fallback T.pack <$> lookupEnv key

stringEnv :: String -> String -> IO String
stringEnv key fallback = maybe fallback id <$> lookupEnv key
