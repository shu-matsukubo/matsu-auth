{-# LANGUAGE OverloadedStrings #-}

module AuthView (authorizationErrorPage, loginPage) where

import Data.Text (Text)
import Lucid
import Lucid.Base (makeAttribute)

loginPage :: Text -> Maybe Text -> Html ()
loginPage requestId maybeError = do
  doctype_
  html_ [lang_ "ja"] $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
      title_ "matsu アカウント"
      style_ pageCss
    body_ $ do
      main_ [class_ "auth-page"] $
        section_ [class_ "auth-panel", makeAttribute "aria-labelledby" "auth-title"] $ do
          header_ [class_ "auth-header"] $ do
            p_ [class_ "eyebrow"] "matsu"
            h1_ [id_ "auth-title"] "アカウントにログイン"
            p_ [class_ "description"] "ログインすると、元のアプリへ安全に戻ります。"
          form_ [method_ "post", action_ "/oauth/authorize", class_ "auth-form"] $ do
            input_ [type_ "hidden", name_ "request_id", value_ requestId]
            label_ $ do
              "メールアドレス"
              input_
                [ type_ "email",
                  name_ "email",
                  autocomplete_ "email",
                  required_ "",
                  autofocus_
                ]
            label_ $ do
              "パスワード"
              input_
                [ type_ "password",
                  name_ "password",
                  autocomplete_ "current-password",
                  minlength_ "8",
                  required_ ""
                ]
            maybe (pure ()) (p_ [class_ "error"] . toHtml) maybeError
            div_ [class_ "actions"] $ do
              button_ [type_ "submit", name_ "action", value_ "login", class_ "primary"] "ログイン"
              button_ [type_ "submit", name_ "action", value_ "register", class_ "secondary"] "新規登録"
          p_ [class_ "footnote"] "パスワードは8文字以上で入力してください。"

authorizationErrorPage :: Text -> Text -> Html ()
authorizationErrorPage loginStartUri message = do
  doctype_
  html_ [lang_ "ja"] $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
      title_ "ログインをやり直してください | matsu"
      style_ pageCss
    body_ $ do
      main_ [class_ "auth-page"] $
        section_ [class_ "auth-panel", makeAttribute "aria-labelledby" "auth-title"] $ do
          header_ [class_ "auth-header"] $ do
            p_ [class_ "eyebrow"] "matsu"
            h1_ [id_ "auth-title"] "ログインをやり直してください"
            p_ [class_ "description"] (toHtml message)
          a_ [href_ loginStartUri, class_ "primary retry-link"] "もう一度ログイン"
          p_ [class_ "footnote"] "この画面を閉じて、アプリからやり直すこともできます。"

pageCss :: Text
pageCss =
  mconcat
    [ ":root{font-family:Inter,\"Noto Sans JP\",system-ui,sans-serif;color:#172033;background:#f4f6f8}",
      "*{box-sizing:border-box}",
      "body{margin:0}",
      ".auth-page{min-height:100vh;display:grid;place-items:center;padding:24px}",
      ".auth-panel{width:min(100%,420px);padding:32px;border:1px solid #dce2e8;border-radius:14px;background:#fff;box-shadow:0 18px 50px rgba(23,32,51,.09)}",
      ".auth-header{margin-bottom:24px}",
      ".eyebrow{margin:0 0 8px;color:#2c6e63;font-size:13px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}",
      "h1{margin:0;font-size:26px;line-height:1.3}",
      ".description{margin:10px 0 0;color:#617083;font-size:14px;line-height:1.6}",
      ".auth-form{display:grid;gap:16px}",
      "label{display:grid;gap:7px;color:#344054;font-size:14px;font-weight:650}",
      "input{width:100%;min-height:44px;padding:0 12px;border:1px solid #c7d0db;border-radius:8px;color:#172033;background:#fff;font:inherit}",
      "input:focus{border-color:#2c6e63;outline:3px solid rgba(44,110,99,.16)}",
      ".error{margin:0;padding:10px 12px;border-radius:8px;color:#a52525;background:#fff1f1;font-size:14px;line-height:1.5}",
      ".actions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:2px}",
      "button{min-height:44px;border-radius:8px;font:inherit;font-weight:700;cursor:pointer}",
      ".primary{border:1px solid #2c6e63;color:#fff;background:#2c6e63}",
      ".primary:hover{background:#245b53}",
      ".retry-link{display:flex;min-height:44px;align-items:center;justify-content:center;border-radius:8px;font-weight:700;text-decoration:none}",
      ".secondary{border:1px solid #b8c3cf;color:#344054;background:#fff}",
      ".secondary:hover{background:#f7f9fb}",
      ".footnote{margin:18px 0 0;color:#7b8797;font-size:12px;text-align:center}",
      "@media(max-width:480px){.auth-page{padding:16px}.auth-panel{padding:24px}.actions{grid-template-columns:1fr}}"
    ]
