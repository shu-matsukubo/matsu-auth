{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import AuthView (authorizationErrorPage, loginPage)
import Control.Monad (unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON (..), Value, eitherDecode, encode, object, (.=))
import qualified Data.Base64.Types as B64Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64Url
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum)
import Data.Int (Int64)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Pool (Pool, defaultPoolConfig, newPool, withResource)
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
    execute_,
    query,
    withTransaction,
  )
import GHC.Generics (Generic)
import Lucid (Html, renderBS)
import Network.HTTP.Types (hContentType, hLocation)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Middleware, mapResponseHeaders, rawPathInfo)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Servant
import Servant.HTML.Lucid (HTML)
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
import Web.FormUrlEncoded
  ( FromForm (..),
    parseMaybe,
    parseUnique,
  )
import qualified Crypto.BCrypt as BCrypt

type API =
  "health" :> Get '[JSON] HealthResponse
    :<|> "auth" :> "register" :> ReqBody '[JSON] AuthRequest :> Post '[JSON] TokenResponse
    :<|> "auth" :> "login" :> ReqBody '[JSON] AuthRequest :> Post '[JSON] TokenResponse
    :<|> "auth" :> "refresh" :> ReqBody '[JSON] RefreshRequest :> Post '[JSON] TokenResponse
    :<|> ".well-known" :> "jwks.json" :> Get '[JSON] Value
    :<|> ".well-known" :> "oauth-authorization-server" :> Get '[JSON] Value
    :<|> "oauth" :> "authorize"
      :> QueryParam' '[Required] "response_type" Text
      :> QueryParam' '[Required] "client_id" Text
      :> QueryParam' '[Required] "redirect_uri" Text
      :> QueryParam "scope" Text
      :> QueryParam' '[Required] "state" Text
      :> QueryParam' '[Required] "code_challenge" Text
      :> QueryParam' '[Required] "code_challenge_method" Text
      :> Get '[HTML] (Html ())
    :<|> "oauth" :> "authorize"
      :> ReqBody '[FormUrlEncoded] AuthorizeForm
      :> Post '[HTML] (Html ())
    :<|> "oauth" :> "token"
      :> ReqBody '[FormUrlEncoded] OAuthTokenRequest
      :> Post '[JSON] OAuthTokenResponse

data AppEnv = AppEnv
  { envPool :: Pool Connection,
    envIssuer :: Text,
    envAudience :: Text,
    envAllowedResources :: [Text],
    envAccessTokenTtl :: NominalDiffTime,
    envRefreshTokenTtl :: NominalDiffTime,
    envAuthorizationRequestTtl :: NominalDiffTime,
    envAuthorizationCodeTtl :: NominalDiffTime,
    envPrivateKeyPath :: FilePath,
    envJwks :: Value,
    envKeyId :: Text,
    envClientId :: Text,
    envClientSecret :: Text,
    envRedirectUri :: Text,
    envScope :: Text,
    envLoginStartUri :: Text
  }

data AuthRequest = AuthRequest
  { email :: Text,
    password :: Text,
    audience :: Maybe Text
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

data OAuthTokenResponse = OAuthTokenResponse
  { oauthAccessToken :: Text,
    oauthRefreshToken :: Text,
    oauthTokenType :: Text,
    oauthExpiresIn :: Int,
    oauthScope :: Text
  }
  deriving (Show)

instance ToJSON OAuthTokenResponse where
  toJSON response =
    object
      [ "access_token" .= oauthAccessToken response,
        "refresh_token" .= oauthRefreshToken response,
        "token_type" .= oauthTokenType response,
        "expires_in" .= oauthExpiresIn response,
        "scope" .= oauthScope response
      ]

data AuthorizeForm = AuthorizeForm
  { authorizeRequestId :: Text,
    authorizeEmail :: Text,
    authorizePassword :: Text,
    authorizeAction :: Text
  }
  deriving (Show)

instance FromForm AuthorizeForm where
  fromForm form =
    AuthorizeForm
      <$> parseUnique "request_id" form
      <*> parseUnique "email" form
      <*> parseUnique "password" form
      <*> parseUnique "action" form

data OAuthTokenRequest = OAuthTokenRequest
  { oauthGrantType :: Text,
    oauthCode :: Maybe Text,
    oauthRedirectUri :: Maybe Text,
    oauthClientId :: Maybe Text,
    oauthClientSecret :: Maybe Text,
    oauthCodeVerifier :: Maybe Text,
    oauthRefreshTokenRequest :: Maybe Text
  }
  deriving (Show)

instance FromForm OAuthTokenRequest where
  fromForm form =
    OAuthTokenRequest
      <$> parseUnique "grant_type" form
      <*> parseMaybe "code" form
      <*> parseMaybe "redirect_uri" form
      <*> parseMaybe "client_id" form
      <*> parseMaybe "client_secret" form
      <*> parseMaybe "code_verifier" form
      <*> parseMaybe "refresh_token" form

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

data AuthorizationRequestRecord = AuthorizationRequestRecord
  { authorizationRequestId :: Text,
    authorizationClientId :: Text,
    authorizationRedirectUri :: Text,
    authorizationState :: Text,
    authorizationScope :: Text,
    authorizationCodeChallenge :: Text
  }

data AuthorizationCodeRecord = AuthorizationCodeRecord
  { codeValue :: Text,
    codeUserSub :: UUID,
    codeUserEmail :: Text,
    codeClientId :: Text,
    codeRedirectUri :: Text,
    codeChallenge :: Text,
    codeScope :: Text
  }

data RefreshTokenRecord = RefreshTokenRecord
  { refreshUser :: UserRecord,
    refreshAudience :: Text
  }

main :: IO ()
main = do
  port <- readEnv "AUTH_PORT" 8080
  databaseUrl <- textEnv "AUTH_DATABASE_URL" "postgres://matsu-auth:matsu-auth-pass@localhost:15432/matsu-auth"
  issuer <- textEnv "AUTH_ISSUER" "http://localhost:18081"
  defaultAudience <- textEnv "AUTH_AUDIENCE" "matsu-api"
  accessTtl <- fromInteger <$> readEnv "AUTH_ACCESS_TOKEN_TTL_SECONDS" 900
  refreshTtl <- fromInteger <$> readEnv "AUTH_REFRESH_TOKEN_TTL_SECONDS" 2592000
  authorizationRequestTtl <- fromInteger <$> readEnv "AUTH_AUTHORIZATION_REQUEST_TTL_SECONDS" 600
  authorizationCodeTtl <- fromInteger <$> readEnv "AUTH_AUTHORIZATION_CODE_TTL_SECONDS" 120
  privateKeyPath <- stringEnv "AUTH_PRIVATE_KEY_PATH" "keys/private.pem"
  jwksPath <- stringEnv "AUTH_JWKS_PATH" "keys/jwks.json"
  keyId <- textEnv "AUTH_KEY_ID" "matsu-dev-key-1"
  allowedOrigin <- textEnv "AUTH_ALLOWED_ORIGIN" "http://localhost:5173"
  clientId <- textEnv "AUTH_CLIENT_ID" "matsu-bff"
  clientSecret <- textEnv "AUTH_CLIENT_SECRET" "matsu-bff-dev-secret"
  redirectUri <- textEnv "AUTH_REDIRECT_URI" "http://localhost:18082/auth/callback"
  scope <- textEnv "AUTH_SCOPE" "matsu-api"
  allowedResourcesRaw <- textEnv "AUTH_ALLOWED_RESOURCES" (defaultAudience <> "," <> scope)
  allowedResources <-
    either (fail . T.unpack) pure (parseAllowedResources defaultAudience scope allowedResourcesRaw)
  loginStartUri <- textEnv "AUTH_LOGIN_START_URI" "http://localhost:18082/auth/login"
  jwksBytes <- BL.readFile jwksPath
  jwks <- either fail pure (eitherDecode jwksBytes)
  pool <-
    newPool $
      defaultPoolConfig
        (connectPostgreSQL (TE.encodeUtf8 databaseUrl))
        close
        10
        10
  ensureOAuthSchema pool
  let env =
        AppEnv
          pool
          issuer
          defaultAudience
          allowedResources
          accessTtl
          refreshTtl
          authorizationRequestTtl
          authorizationCodeTtl
          privateKeyPath
          jwks
          keyId
          clientId
          clientSecret
          redirectUri
          scope
          loginStartUri
  putStrLn ("matsu auth listening on :" <> show port)
  run
    port
    ( securityHeadersMiddleware
        redirectUri
        allowedOrigin
        (corsMiddleware allowedOrigin (serve (Proxy :: Proxy API) (server env)))
    )

server :: AppEnv -> Server API
server env =
  pure (HealthResponse "ok")
    :<|> registerHandler env
    :<|> loginHandler env
    :<|> refreshHandler env
    :<|> pure (envJwks env)
    :<|> pure (authorizationServerMetadata env)
    :<|> authorizePageHandler env
    :<|> authorizeSubmitHandler env
    :<|> oauthTokenHandler env

registerHandler :: AppEnv -> AuthRequest -> Handler TokenResponse
registerHandler env req = do
  validateAuthRequest req
  selectedAudience <- validateAudience env (audience req)
  result <- liftIO $ registerUser env (email req) (password req)
  case result of
    Left message -> throwError err409 {errBody = BL.fromStrict (TE.encodeUtf8 message)}
    Right user -> issueTokens env selectedAudience (userSub user) (userEmail user)

loginHandler :: AppEnv -> AuthRequest -> Handler TokenResponse
loginHandler env req = do
  validateAuthRequest req
  selectedAudience <- validateAudience env (audience req)
  result <- liftIO $ authenticateUser env (email req) (password req)
  case result of
    Left _ -> throwError err401 {errBody = "invalid credentials"}
    Right user -> issueTokens env selectedAudience (userSub user) (userEmail user)

refreshHandler :: AppEnv -> RefreshRequest -> Handler TokenResponse
refreshHandler env (RefreshRequest token) = snd <$> refreshTokens env token

authorizePageHandler ::
  AppEnv ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Handler (Html ())
authorizePageHandler env responseType clientId redirectUri maybeScope state challenge challengeMethod = do
  scope <- validateAuthorizationRequest env responseType clientId redirectUri maybeScope state challenge challengeMethod
  requestId <- liftIO randomToken
  now <- liftIO getCurrentTime
  let request =
        AuthorizationRequestRecord
          requestId
          clientId
          redirectUri
          state
          scope
          challenge
  liftIO $ insertAuthorizationRequest env request (addUTCTime (envAuthorizationRequestTtl env) now)
  pure (loginPage requestId Nothing)

authorizeSubmitHandler :: AppEnv -> AuthorizeForm -> Handler (Html ())
authorizeSubmitHandler env form = do
  maybeRequest <- liftIO $ findAuthorizationRequest env (authorizeRequestId form)
  case maybeRequest of
    Nothing ->
      throwAuthorizationPageError
        env
        "ログイン情報の有効期限が切れたか、すでに使用されています。"
    Just request ->
      case credentialValidationError (authorizeEmail form) (authorizePassword form) of
        Just message -> pure (loginPage (authorizeRequestId form) (Just message))
        Nothing -> do
          userResult <-
            liftIO $
              case authorizeAction form of
                "register" -> registerUser env (authorizeEmail form) (authorizePassword form)
                "login" -> authenticateUser env (authorizeEmail form) (authorizePassword form)
                _ -> pure (Left "操作を選択できませんでした。")
          case userResult of
            Left message -> pure (loginPage (authorizeRequestId form) (Just message))
            Right user -> do
              code <- liftIO randomToken
              now <- liftIO getCurrentTime
              created <-
                liftIO $
                  createAuthorizationCode
                    env
                    request
                    user
                    code
                    (addUTCTime (envAuthorizationCodeTtl env) now)
              unless created $
                throwAuthorizationPageError
                  env
                  "ログイン情報の有効期限が切れたか、すでに使用されています。"
              let location = authorizationCallbackLocation request code
              throwError err303 {errHeaders = [(hLocation, TE.encodeUtf8 location)]}

oauthTokenHandler :: AppEnv -> OAuthTokenRequest -> Handler OAuthTokenResponse
oauthTokenHandler env request = do
  validateOAuthClient env request
  case oauthGrantType request of
    "authorization_code" -> authorizationCodeGrant env request
    "refresh_token" -> refreshTokenGrant env request
    _ -> throwOAuthError err400 "unsupported_grant_type" "The grant_type is not supported."

authorizationCodeGrant :: AppEnv -> OAuthTokenRequest -> Handler OAuthTokenResponse
authorizationCodeGrant env request = do
  code <- requireOAuthField "code" (oauthCode request)
  redirectUri <- requireOAuthField "redirect_uri" (oauthRedirectUri request)
  clientId <- requireOAuthField "client_id" (oauthClientId request)
  verifier <- requireOAuthField "code_verifier" (oauthCodeVerifier request)
  unless (validPkceVerifier verifier) $
    throwOAuthError err400 "invalid_grant" "The code_verifier is invalid."
  maybeCode <- liftIO $ findAuthorizationCode env code
  case maybeCode of
    Nothing -> throwOAuthError err400 "invalid_grant" "The authorization code is invalid or expired."
    Just record -> do
      unless
        ( codeClientId record == clientId
            && codeRedirectUri record == redirectUri
        )
        $ throwOAuthError err400 "invalid_grant" "The authorization code does not match this client."
      actualChallenge <- liftIO $ pkceChallenge verifier
      unless (actualChallenge == codeChallenge record) $
        throwOAuthError err400 "invalid_grant" "PKCE verification failed."
      consumed <- liftIO $ consumeAuthorizationCode env (codeValue record)
      unless consumed $
        throwOAuthError err400 "invalid_grant" "The authorization code was already used."
      tokens <- issueTokens env (codeScope record) (codeUserSub record) (codeUserEmail record)
      pure (toOAuthTokenResponse (codeScope record) tokens)

refreshTokenGrant :: AppEnv -> OAuthTokenRequest -> Handler OAuthTokenResponse
refreshTokenGrant env request = do
  token <- requireOAuthField "refresh_token" (oauthRefreshTokenRequest request)
  (tokenAudience, tokens) <- refreshTokens env token
  pure (toOAuthTokenResponse tokenAudience tokens)

refreshTokens :: AppEnv -> Text -> Handler (Text, TokenResponse)
refreshTokens env token = do
  maybeRecord <- liftIO $ consumeRefreshToken env token
  case maybeRecord of
    Nothing -> throwError err401 {errBody = "invalid refresh token"}
    Just record -> do
      let user = refreshUser record
          tokenAudience = refreshAudience record
      tokens <- issueTokens env tokenAudience (userSub user) (userEmail user)
      pure (tokenAudience, tokens)

validateOAuthClient :: AppEnv -> OAuthTokenRequest -> Handler ()
validateOAuthClient env request =
  unless
    ( oauthClientId request == Just (envClientId env)
        && oauthClientSecret request == Just (envClientSecret env)
    )
    $ throwOAuthError err401 "invalid_client" "Client authentication failed."

requireOAuthField :: Text -> Maybe Text -> Handler Text
requireOAuthField fieldName maybeValue =
  case maybeValue of
    Just value | not (T.null value) -> pure value
    _ -> throwOAuthError err400 "invalid_request" ("Missing " <> fieldName <> ".")

throwOAuthError :: ServerError -> Text -> Text -> Handler a
throwOAuthError baseError errorCode description =
  throwError
    baseError
      { errBody =
          encode
            ( object
                [ "error" .= errorCode,
                  "error_description" .= description
                ]
            ),
        errHeaders = [(hContentType, "application/json; charset=utf-8")]
      }

validateAuthorizationRequest ::
  AppEnv ->
  Text ->
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Text ->
  Text ->
  Handler Text
validateAuthorizationRequest env responseType clientId redirectUri maybeScope state challenge challengeMethod = do
  let invalidRequest =
        throwAuthorizationPageError
          env
          "ログインを開始できませんでした。アプリからもう一度お試しください。"
  unless (responseType == "code") invalidRequest
  unless (clientId == envClientId env) invalidRequest
  unless (redirectUri == envRedirectUri env) invalidRequest
  unless (challengeMethod == "S256") invalidRequest
  unless (validPkceChallenge challenge) invalidRequest
  unless (not (T.null state) && T.length state <= 512) invalidRequest
  let scope = fromMaybe (envScope env) maybeScope
  unless (scope `elem` envAllowedResources env) invalidRequest
  pure scope

throwAuthorizationPageError :: AppEnv -> Text -> Handler a
throwAuthorizationPageError env message =
  throwError
    err400
      { errBody = renderBS (authorizationErrorPage (envLoginStartUri env) message),
        errHeaders = [(hContentType, "text/html; charset=utf-8")]
      }

validPkceChallenge :: Text -> Bool
validPkceChallenge value = T.length value == 43 && T.all isPkceCharacter value

validPkceVerifier :: Text -> Bool
validPkceVerifier value =
  T.length value >= 43
    && T.length value <= 128
    && T.all isPkceCharacter value

isPkceCharacter :: Char -> Bool
isPkceCharacter character =
  isAlphaNum character || character `elem` ("-._~" :: String)

validateAuthRequest :: AuthRequest -> Handler ()
validateAuthRequest req =
  case credentialValidationError (email req) (password req) of
    Nothing -> pure ()
    Just message -> throwError err400 {errBody = BL.fromStrict (TE.encodeUtf8 message)}

credentialValidationError :: Text -> Text -> Maybe Text
credentialValidationError emailAddress rawPassword
  | T.length rawPassword < 8 = Just "パスワードは8文字以上で入力してください。"
  | not ("@" `T.isInfixOf` emailAddress) = Just "メールアドレスを確認してください。"
  | otherwise = Nothing

validateAudience :: AppEnv -> Maybe Text -> Handler Text
validateAudience env maybeAudience = do
  let selectedAudience = fromMaybe (envAudience env) maybeAudience
  unless
    (not (T.null selectedAudience) && selectedAudience `elem` envAllowedResources env)
    (throwError err400 {errBody = "unsupported audience"})
  pure selectedAudience

authenticateUser :: AppEnv -> Text -> Text -> IO (Either Text UserRecord)
authenticateUser env emailAddress rawPassword = do
  maybeUser <- findUserByEmail env emailAddress
  pure $
    case maybeUser of
      Nothing -> Left "メールアドレスまたはパスワードが正しくありません。"
      Just user ->
        if BCrypt.validatePassword (TE.encodeUtf8 (userPasswordHash user)) (TE.encodeUtf8 rawPassword)
          then Right user
          else Left "メールアドレスまたはパスワードが正しくありません。"

registerUser :: AppEnv -> Text -> Text -> IO (Either Text UserRecord)
registerUser env emailAddress rawPassword = do
  maybeExisting <- findUserByEmail env emailAddress
  case maybeExisting of
    Just _ -> pure (Left "このメールアドレスはすでに登録されています。")
    Nothing -> do
      sub <- nextRandom
      hash <- hashPassword rawPassword
      _ <- insertUser env sub emailAddress hash
      pure (Right (UserRecord sub emailAddress hash))

hashPassword :: Text -> IO Text
hashPassword raw = do
  maybeHash <- BCrypt.hashPasswordUsingPolicy BCrypt.slowerBcryptHashingPolicy (TE.encodeUtf8 raw)
  case maybeHash of
    Nothing -> fail "failed to hash password"
    Just hashed -> pure (TE.decodeUtf8 hashed)

issueTokens :: AppEnv -> Text -> UUID -> Text -> Handler TokenResponse
issueTokens env tokenAudience sub emailAddress = do
  now <- liftIO getCurrentTime
  access <- liftIO $ makeAccessToken env tokenAudience now sub emailAddress
  refresh <- liftIO randomToken
  _ <-
    liftIO $
      insertRefreshToken
        env
        refresh
        sub
        tokenAudience
        (addUTCTime (envRefreshTokenTtl env) now)
  pure
    TokenResponse
      { accessToken = access,
        refreshToken = refresh,
        tokenType = "Bearer",
        expiresIn = floor (envAccessTokenTtl env)
      }

toOAuthTokenResponse :: Text -> TokenResponse -> OAuthTokenResponse
toOAuthTokenResponse scope (TokenResponse access refresh tokenKind lifetime) =
  OAuthTokenResponse
    { oauthAccessToken = access,
      oauthRefreshToken = refresh,
      oauthTokenType = tokenKind,
      oauthExpiresIn = lifetime,
      oauthScope = scope
    }

makeAccessToken :: AppEnv -> Text -> UTCTime -> UUID -> Text -> IO Text
makeAccessToken env tokenAudience now sub emailAddress = do
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
            "aud" .= tokenAudience,
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
signRS256 privateKeyPath =
  runOpenSsl ["dgst", "-sha256", "-sign", privateKeyPath, "-binary"]

pkceChallenge :: Text -> IO Text
pkceChallenge verifier =
  base64Url <$> runOpenSsl ["dgst", "-sha256", "-binary"] (TE.encodeUtf8 verifier)

runOpenSsl :: [String] -> BS.ByteString -> IO BS.ByteString
runOpenSsl arguments input =
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
          _ -> fail ("openssl command failed: " <> show errOutput)
      _ -> fail "failed to open openssl process handles"
  where
    opensslProcess =
      (proc "openssl" arguments)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe
        }

randomToken :: IO Text
randomToken = do
  first <- nextRandom
  second <- nextRandom
  pure (T.filter (/= '-') (UUID.toText first <> UUID.toText second))

authorizationCallbackLocation :: AuthorizationRequestRecord -> Text -> Text
authorizationCallbackLocation request code =
  authorizationRedirectUri request
    <> separator
    <> "code="
    <> queryEncode code
    <> "&state="
    <> queryEncode (authorizationState request)
  where
    separator
      | "?" `T.isInfixOf` authorizationRedirectUri request = "&"
      | otherwise = "?"

queryEncode :: Text -> Text
queryEncode = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

authorizationServerMetadata :: AppEnv -> Value
authorizationServerMetadata env =
  object
    [ "issuer" .= envIssuer env,
      "authorization_endpoint" .= issuerEndpoint env "/oauth/authorize",
      "token_endpoint" .= issuerEndpoint env "/oauth/token",
      "jwks_uri" .= issuerEndpoint env "/.well-known/jwks.json",
      "response_types_supported" .= [("code" :: Text)],
      "grant_types_supported" .= [("authorization_code" :: Text), "refresh_token"],
      "code_challenge_methods_supported" .= [("S256" :: Text)],
      "token_endpoint_auth_methods_supported" .= [("client_secret_post" :: Text)],
      "scopes_supported" .= envAllowedResources env
    ]

issuerEndpoint :: AppEnv -> Text -> Text
issuerEndpoint env path = T.dropWhileEnd (== '/') (envIssuer env) <> path

findUserByEmail :: AppEnv -> Text -> IO (Maybe UserRecord)
findUserByEmail env targetEmail =
  withResource (envPool env) $ \conn -> do
    rows <- query conn "SELECT sub, email, password_hash FROM users WHERE email = ?" (Only targetEmail)
    pure (rowToUser <$> firstMaybe rows)

consumeRefreshToken :: AppEnv -> Text -> IO (Maybe RefreshTokenRecord)
consumeRefreshToken env token =
  withResource (envPool env) $ \conn -> do
    rows <-
      query
        conn
        "WITH revoked AS (UPDATE refresh_tokens SET revoked_at = now() WHERE token = ? AND revoked_at IS NULL AND expires_at > now() RETURNING user_sub, audience) SELECT users.sub, users.email, users.password_hash, revoked.audience FROM revoked INNER JOIN users ON users.sub = revoked.user_sub"
        (Only token)
    pure (rowToRefreshToken <$> firstMaybe rows)

insertUser :: AppEnv -> UUID -> Text -> Text -> IO Int64
insertUser env sub emailAddress passwordHash =
  withResource (envPool env) $ \conn ->
    execute
      conn
      "INSERT INTO users (sub, email, password_hash) VALUES (?, ?, ?)"
      (sub, emailAddress, passwordHash)

insertRefreshToken :: AppEnv -> Text -> UUID -> Text -> UTCTime -> IO Int64
insertRefreshToken env token sub tokenAudience expiresAt =
  withResource (envPool env) $ \conn ->
    execute
      conn
      "INSERT INTO refresh_tokens (token, user_sub, audience, expires_at) VALUES (?, ?, ?, ?)"
      (token, sub, tokenAudience, expiresAt)

insertAuthorizationRequest :: AppEnv -> AuthorizationRequestRecord -> UTCTime -> IO ()
insertAuthorizationRequest env request expiresAt =
  withResource (envPool env) $ \conn -> do
    void $
      execute
        conn
        "INSERT INTO authorization_requests (request_id, client_id, redirect_uri, state, scope, code_challenge, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
        ( authorizationRequestId request,
          authorizationClientId request,
          authorizationRedirectUri request,
          authorizationState request,
          authorizationScope request,
          authorizationCodeChallenge request,
          expiresAt
        )

findAuthorizationRequest :: AppEnv -> Text -> IO (Maybe AuthorizationRequestRecord)
findAuthorizationRequest env requestId =
  withResource (envPool env) $ \conn -> do
    rows <-
      query
        conn
        "SELECT request_id, client_id, redirect_uri, state, scope, code_challenge FROM authorization_requests WHERE request_id = ? AND used_at IS NULL AND expires_at > now()"
        (Only requestId)
    pure (rowToAuthorizationRequest <$> firstMaybe rows)

createAuthorizationCode ::
  AppEnv ->
  AuthorizationRequestRecord ->
  UserRecord ->
  Text ->
  UTCTime ->
  IO Bool
createAuthorizationCode env request user code expiresAt =
  withResource (envPool env) $ \conn ->
    withTransaction conn $ do
      claimed <-
        execute
          conn
          "UPDATE authorization_requests SET used_at = now() WHERE request_id = ? AND used_at IS NULL AND expires_at > now()"
          (Only (authorizationRequestId request))
      if claimed /= 1
        then pure False
        else do
          _ <-
            execute
              conn
              "INSERT INTO authorization_codes (code, user_sub, client_id, redirect_uri, code_challenge, scope, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
              ( code,
                userSub user,
                authorizationClientId request,
                authorizationRedirectUri request,
                authorizationCodeChallenge request,
                authorizationScope request,
                expiresAt
              )
          pure True

findAuthorizationCode :: AppEnv -> Text -> IO (Maybe AuthorizationCodeRecord)
findAuthorizationCode env code =
  withResource (envPool env) $ \conn -> do
    rows <-
      query
        conn
        "SELECT authorization_codes.code, users.sub, users.email, authorization_codes.client_id, authorization_codes.redirect_uri, authorization_codes.code_challenge, authorization_codes.scope FROM authorization_codes INNER JOIN users ON users.sub = authorization_codes.user_sub WHERE authorization_codes.code = ? AND authorization_codes.used_at IS NULL AND authorization_codes.expires_at > now()"
        (Only code)
    pure (rowToAuthorizationCode <$> firstMaybe rows)

consumeAuthorizationCode :: AppEnv -> Text -> IO Bool
consumeAuthorizationCode env code =
  withResource (envPool env) $ \conn -> do
    updated <-
      execute
        conn
        "UPDATE authorization_codes SET used_at = now() WHERE code = ? AND used_at IS NULL AND expires_at > now()"
        (Only code)
    pure (updated == 1)

rowToUser :: (UUID, Text, Text) -> UserRecord
rowToUser (sub, emailAddress, passwordHash) = UserRecord sub emailAddress passwordHash

rowToRefreshToken :: (UUID, Text, Text, Text) -> RefreshTokenRecord
rowToRefreshToken (sub, emailAddress, passwordHash, tokenAudience) =
  RefreshTokenRecord (UserRecord sub emailAddress passwordHash) tokenAudience

rowToAuthorizationRequest :: (Text, Text, Text, Text, Text, Text) -> AuthorizationRequestRecord
rowToAuthorizationRequest (requestId, clientId, redirectUri, state, scope, challenge) =
  AuthorizationRequestRecord requestId clientId redirectUri state scope challenge

rowToAuthorizationCode :: (Text, UUID, Text, Text, Text, Text, Text) -> AuthorizationCodeRecord
rowToAuthorizationCode (code, sub, emailAddress, clientId, redirectUri, challenge, scope) =
  AuthorizationCodeRecord code sub emailAddress clientId redirectUri challenge scope

firstMaybe :: [a] -> Maybe a
firstMaybe [] = Nothing
firstMaybe (x : _) = Just x

b64Json :: ToJSON a => a -> Text
b64Json = base64Url . BL.toStrict . encode

base64Url :: BS.ByteString -> Text
base64Url = B64Types.extractBase64 . B64Url.encodeBase64Unpadded

ensureOAuthSchema :: Pool Connection -> IO ()
ensureOAuthSchema pool =
  withResource pool $ \conn -> do
    void $
      execute_
        conn
        "ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS audience text"
    void $
      execute_
        conn
        "UPDATE refresh_tokens SET audience = 'matsu-api' WHERE audience IS NULL"
    void $
      execute_
        conn
        "ALTER TABLE refresh_tokens ALTER COLUMN audience SET DEFAULT 'matsu-api'"
    void $
      execute_
        conn
        "ALTER TABLE refresh_tokens ALTER COLUMN audience SET NOT NULL"
    void $
      execute_
        conn
        "CREATE TABLE IF NOT EXISTS authorization_requests (request_id text PRIMARY KEY, client_id text NOT NULL, redirect_uri text NOT NULL, state text NOT NULL, scope text NOT NULL, code_challenge text NOT NULL, expires_at timestamptz NOT NULL, used_at timestamptz, created_at timestamptz NOT NULL DEFAULT now())"
    void $
      execute_
        conn
        "CREATE INDEX IF NOT EXISTS authorization_requests_expires_at_idx ON authorization_requests(expires_at)"
    void $
      execute_
        conn
        "CREATE TABLE IF NOT EXISTS authorization_codes (code text PRIMARY KEY, user_sub uuid NOT NULL REFERENCES users(sub) ON DELETE CASCADE, client_id text NOT NULL, redirect_uri text NOT NULL, code_challenge text NOT NULL, scope text NOT NULL, expires_at timestamptz NOT NULL, used_at timestamptz, created_at timestamptz NOT NULL DEFAULT now())"
    void $
      execute_
        conn
        "CREATE INDEX IF NOT EXISTS authorization_codes_expires_at_idx ON authorization_codes(expires_at)"

corsMiddleware :: Text -> Middleware
corsMiddleware allowedOrigin =
  cors $ \request ->
    if rawPathInfo request == "/oauth/authorize"
      then Nothing
      else
        Just
          simpleCorsResourcePolicy
            { corsOrigins = Just ([TE.encodeUtf8 allowedOrigin], True),
              corsMethods = ["GET", "POST", "OPTIONS"],
              corsRequestHeaders = ["authorization", "content-type"],
              corsExposedHeaders = Just [hContentType]
            }

securityHeadersMiddleware :: Text -> Text -> Middleware
securityHeadersMiddleware redirectUri frontendOrigin application request sendResponse =
  application request (sendResponse . mapResponseHeaders (securityHeaders <>))
  where
    securityHeaders =
      [ ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Frame-Options", "DENY")
      ]
        <> authorizationPageHeaders
    authorizationPageHeaders
      | rawPathInfo request == "/oauth/authorize" =
          [ ("Cache-Control", "no-store"),
            ( "Content-Security-Policy",
              TE.encodeUtf8
                ( "default-src 'none'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self' "
                    <> redirectUri
                    <> " "
                    <> frontendOrigin
                    <> "; frame-ancestors 'none'; base-uri 'none'"
                )
            )
          ]
      | otherwise = []

readEnv :: Read a => String -> a -> IO a
readEnv key fallback = maybe fallback read <$> lookupEnv key

textEnv :: String -> Text -> IO Text
textEnv key fallback = maybe fallback T.pack <$> lookupEnv key

stringEnv :: String -> String -> IO String
stringEnv key fallback = maybe fallback id <$> lookupEnv key

parseAllowedResources :: Text -> Text -> Text -> Either Text [Text]
parseAllowedResources defaultAudience defaultScope raw = do
  let resources = nub (filter (not . T.null) (map T.strip (T.splitOn "," raw)))
  unlessEither (not (null resources)) "AUTH_ALLOWED_RESOURCES must contain at least one resource."
  unlessEither
    (defaultAudience `elem` resources)
    "AUTH_AUDIENCE must be included in AUTH_ALLOWED_RESOURCES."
  unlessEither
    (defaultScope `elem` resources)
    "AUTH_SCOPE must be included in AUTH_ALLOWED_RESOURCES."
  pure resources

unlessEither :: Bool -> Text -> Either Text ()
unlessEither condition message
  | condition = Right ()
  | otherwise = Left message
