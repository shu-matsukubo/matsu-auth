# matsu-auth

`matsu` ワークスペースの認証サーバーです。ブラウザのログインを受け付け、BFF を介して家計簿 API と Toolbox API で利用するトークンを発行します。Arcade の認証は独立した `matsu-arcade-auth` が担当します。

## 必要条件

- Docker Desktop または Docker Engine
- Docker Compose v2

Haskell のローカルツールチェーンは、Docker だけで開発する場合は不要です。

## 初回準備

リポジトリに含まれる次の鍵を確認してください。どちらもローカル開発専用で、追加生成は不要です。

- `keys/private.pem`
- `keys/jwks.json`

これらの鍵と `docker-compose.yml` の認証情報を、本番環境の secret として使用しないでください。本番相当の環境では、鍵と認証情報をリポジトリ外で管理します。

## 起動と停止

初回起動またはイメージを更新するときは、Auth と依存する PostgreSQL を起動します。

```bash
docker compose up -d --build auth
```

- Auth: `http://localhost:18081`
- PostgreSQL: `localhost:15432`

起動確認:

```bash
curl http://localhost:18081/health
```

ログ確認:

```bash
docker compose logs -f auth
```

停止:

```bash
docker compose down
```

通常の停止では named volume を削除しません。DB を初期化する目的がない限り `docker compose down -v` は使用しないでください。

## 開発

ソースを変更した後はイメージを再ビルドし、Auth を再作成します。

```bash
docker compose build auth
docker compose up -d auth
```

アプリケーションの依存関係と build 設定は `matsu-auth.cabal`、Docker build は `Dockerfile` を正本とします。ポート、DB 接続、issuer、許可する resource、BFF の callback、鍵のパスなどのローカル設定は `docker-compose.yml` を確認してください。

DB の初期スキーマは、空の named volume で PostgreSQL を初回起動したときに `db/init/` から適用されます。

## 品質確認

現在、GitHub Actions の CI と自動 test-suite は導入されていません。変更時は少なくとも次を確認してください。

```bash
docker compose build auth
docker compose up -d auth
curl http://localhost:18081/health
```

認証フロー全体へ影響する変更では、BFF と対象 resource server を含むローカル環境で動作を確認します。

## 設計資料

- [Auth の責務と技術選定](https://github.com/shu-matsukubo/matsu-docs/blob/main/docs/components/auth.md)
- [API 契約](https://github.com/shu-matsukubo/matsu-docs/blob/main/docs/architecture/api-contracts.md)
- [認証とセッション](https://github.com/shu-matsukubo/matsu-docs/blob/main/docs/architecture/authentication.md)
- [CI・静的解析・品質ゲート](https://github.com/shu-matsukubo/matsu-docs/blob/main/docs/architecture/quality-gates.md)
