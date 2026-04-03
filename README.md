# php-my-admin-lambda-web-adapter

[phpmyadmin-with-basic-auth](https://github.com/7474/phpmyadmin-with-basic-auth) を [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) で動作させるための構成です。

## Usage

`PMA_SSL` 環境変数に `1` を設定することで SSL/TLS 設定を有効にしてサーバに接続するようになります。
PlanetScale などの DBaaS に接続する際に設定します。

コンテナは **8080** ポートでリッスンします (Lambda Web Adapter のデフォルトポート)。

## Architecture

```
CloudFront (CDN) → Lambda Function URL → Lambda (phpMyAdmin + Lambda Web Adapter)
```

- **Lambda Web Adapter**: Lambda 呼び出しを HTTP リクエストに変換してコンテナ内の Apache へ転送します。
- **CloudFront**: CDN として Lambda Function URL の前段に配置します。

## Notes

### 認証について

このテンプレートでは Lambda 側に基本認証機能を実装していません。理由は以下の通りです：

- **Lambda Function URL のヘッダ変換**: Lambda Function URL 経由で返される `WWW-Authenticate` ヘッダが `x-amzn-Remapped-www-authenticate` に変換され、ブラウザの Basic 認証ダイアログが表示されないためです。
- **Lambda 側での認証は無効**: Apache で Basic 認証を設定しても、ブラウザが認証を要求できず、ユーザーは認証なしで (401 エラーで) ブロックされるだけになります。

基本認証やアクセス制限が必要な場合は、以下の代替手段を推奨します：

1. **CloudFront Functions**（推奨）
   - CloudFront フロントで Basic 認証を実装
   - `WWW-Authenticate` ヘッダをクライアントに返すことで、ブラウザのダイアログが正常に動作
   - サーバレス、低レイテンシ

2. **AWS WAF**
   - CloudFront に紐付けて IP ホワイトリストや地域制限、レート制限などを適用

3. **Amazon Cognito**
   - OAuth 2.0 / OpenID Connect による認証
   - CloudFront + Lambda@Edge や ALB と組み合わせて実装

4. **IAM 認証（現在の構成）**
   - CloudFront の Origin Access Control (OAC) + Lambda Function URL の `AWS_IAM` 認証で、プログラマティックアクセスを保護

### セッションについて

Lambda はステートレスな実行環境であるため、通常の PHP ファイルセッションは以下の問題を抱えています。

| 問題 | 説明 |
|------|------|
| コールドスタート | 新しいコンテナインスタンスが起動するたびに `/tmp` のセッションファイルが失われる |
| 複数インスタンス | 同時リクエストが別インスタンスで処理されると、互いのセッションを参照できない |

この構成では **Cookie ベースのセッションハンドラー** ([`src/cookie-session-handler.php`](src/cookie-session-handler.php)) を実装しており、これらの問題を解決します。

#### 仕組み

セッションデータをサーバ側ではなくブラウザのクッキーに保存します。

```
ログイン → session_write → AES-256-CBC 暗号化 + HMAC-SHA256 署名 → Cookie に保存
次リクエスト → Cookie 取得 → HMAC 検証 → 復号 → session_read → phpMyAdmin に渡す
```

#### セキュリティ仕様

| 項目 | 仕様 |
|------|------|
| 暗号化 | AES-256-CBC |
| 鍵導出 | `SHA-256(PMA_BLOWFISH_SECRET)` → 32 バイト固定長 |
| 整合性 | HMAC-SHA256（Encrypt-then-MAC） |
| Cookie 属性 | `HttpOnly`, `SameSite=Strict`, HTTPS 時 `Secure` |
| HTTPS 判定 | `$_SERVER['HTTPS']` および `X-Forwarded-Proto: https`（CloudFront）に対応 |
| クッキー名 | `PMA_SESS` |

> **注意**: セッションデータはクッキーに保存されるため、セッションサイズが 4 KB 以内に収まる必要があります。phpMyAdmin の通常利用では問題ありません。

#### 環境変数

| 変数 | 必須 | 説明 |
|------|------|------|
| `PMA_BLOWFISH_SECRET` | ○ | 暗号化キーとして使用。32 文字以上のランダム文字列を推奨 |

`PMA_BLOWFISH_SECRET` が未設定の場合、Cookie セッションハンドラーは登録されず、`/tmp` へのファイルセッションにフォールバックします（インスタンスローカルなステートフルセッション）。

#### 設定例

**docker-compose（ローカル開発）**

```yaml
services:
  phpmyadmin:
    build: .
    environment:
      PMA_ARBITRARY: 1
      PMA_BLOWFISH_SECRET: "your-random-32-char-secret-here!!"
    ports:
      - "8080:8080"
```

**Terraform（Lambda 環境変数）**

```hcl
resource "aws_lambda_function" "phpmyadmin" {
  # ...
  environment {
    variables = {
      PMA_ARBITRARY       = "1"
      PMA_BLOWFISH_SECRET = var.pma_blowfish_secret  # AWS Secrets Manager などから取得
    }
  }
}
```

`PMA_BLOWFISH_SECRET` は AWS Secrets Manager または SSM Parameter Store（SecureString）で管理し、Terraform `var` や Lambda の環境変数として注入することを推奨します。

## Directory Structure

- [`src/`](src/) - コンテナイメージのソース
  - [`Dockerfile`](src/Dockerfile) - Lambda Web Adapter を組み込んだ phpMyAdmin イメージ
  - [`config.user.inc.php`](src/config.user.inc.php) - phpMyAdmin SSL設定
  - [`docker-compose.yml`](src/docker-compose.yml) - ローカル開発用 docker-compose
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) - ECR Public / GHCR へのイメージ Push ワークフロー
- [`ecr-terraform/`](ecr-terraform/) - ECR Public リポジトリと GitHub Actions OIDC ロールの Terraform
- [`example-terraform/`](example-terraform/) - Lambda + CloudFront デプロイ例の Terraform

## Setup

### 1. ECR Public リポジトリの作成

```bash
cd ecr-terraform
terraform init
terraform apply
```

`github_actions_role_arn` と `repository_uri` の出力値を控えておきます。

### 2. GitHub Secrets の設定

| Secret | 説明 |
|--------|------|
| `AWS_ROLE_ARN` | ecr-terraform で作成した GitHub Actions IAM ロール ARN |
| `ECR_PUBLIC_ALIAS` | ECR Public エイリアス (例: `g2g6t4l2`) |

### 3. イメージの Push

`main` ブランチへの push または `v*.*.*` タグの作成で自動的にイメージが ECR Public と GHCR へ Push されます。

### 4. Lambda へのデプロイ

AWS Lambda は **ECR Public** のイメージと **ECR pull through cache** のイメージを直接実行できません。  
`public.ecr.aws/...` や `xxxxxxxxxxxx.dkr.ecr.<region>.amazonaws.com/ecr-public/...` を `image_uri` に指定すると、以下のようなエラーになることがあります。

```text
InvalidParameterValueException: The image manifest, config or layer media type for the source image is not supported.
```

そのため、Lambda と **同じリージョンの private ECR** にイメージをコピーして、その URI を `image_uri` に指定してください。

```bash
aws ecr create-repository \
  --region ap-northeast-1 \
  --repository-name phpmyadmin-lambda-adapter

aws ecr get-login-password --region ap-northeast-1 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com

docker pull public.ecr.aws/<alias>/phpmyadmin-lambda-adapter:latest
docker tag public.ecr.aws/<alias>/phpmyadmin-lambda-adapter:latest \
  <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest
docker push <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest
```

```bash
cd example-terraform
terraform init
terraform apply \
  -var="image_uri=<account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest"
```

## Example

- [`src/docker-compose.yml`](src/docker-compose.yml): ローカル開発用 docker-compose の例
- [`example-terraform/`](example-terraform/): AWS Lambda + CloudFront にホスティングする Terraform コードの例
