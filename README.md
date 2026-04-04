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

1. **VPCアクセス（Lambda VPC 配置時）**
   - `subnet_ids` と `security_group_ids` を指定することで Lambda を VPC 内に配置し、プライベートサブネットの RDS / Aurora に接続できます。

### アクセス制御について

Lambda Function URL はパブリックに公開されています。直接アクセスを防ぐために、CloudFront とLambda の両側で多層防御を実装しています。

#### 仕組み

```
CloudFront → (X-Origin-Verify: <secret>) → Lambda Function URL → Apache → phpMyAdmin
                                                                  ↑
                                              ヘッダが一致しない場合 403 を返す
```

1. CloudFront がオリジンへリクエストを転送する際に `X-Origin-Verify` ヘッダにシークレット値を付加します（`cloudfront_origin_secret` variable）。
2. Lambda の Apache が `CLOUDFRONT_ORIGIN_SECRET` 環境変数と照合し、一致しない場合は HTTP 403 を返します。
3. CloudFront は `X-Origin-Verify` ヘッダをビューアへは転送しないため、シークレット値が外部に漏れません。

#### なぜ OAC（AWS_IAM）を使わないのか

CloudFront OAC は SigV4 署名を付与しますが、**POST ボディのハッシュを計算しません**（`unsigned-payload` 扱い）。  
一方、Lambda Function URL は受信したボディのハッシュを自ら計算して SigV4 署名を検証するため、**ボディハッシュが存在しない（unsigned-payload）署名を拒否し、POST リクエストが 403 エラーになります**。

ボディハッシュを正しく含めた署名を生成するには Lambda@Edge など別途コンピューティングリソースが必要です。このテンプレートではそのコストを避けるためカスタムヘッダ方式を採用しています。

| リクエスト | OAC（AWS_IAM）| カスタムヘッダ（NONE）|
|---|---|---|
| GET | ✅ 成功（ボディなし） | ✅ 成功 |
| POST | ❌ ボディハッシュ未計算（unsigned-payload）で署名検証失敗 | ✅ 成功 |

> **参考**: [Restricting access to a Lambda function URL - Amazon CloudFront](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)

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

4. **カスタムヘッダ認証（現在の構成）**
   - CloudFront がオリジンへ `X-Origin-Verify` ヘッダを付加し、Lambda の Apache がヘッダを検証
   - POST リクエストの SigV4 ボディハッシュ不一致問題を回避

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
| `PMA_BLOWFISH_SECRET` | ○ | Cookie セッション暗号化キー。32 文字以上のランダム文字列を推奨 |
| `CLOUDFRONT_ORIGIN_SECRET` | △ | CloudFront カスタムオリジンヘッダと一致するシークレット。Lambda 環境では必須。未設定時はヘッダ検証をスキップ（ローカル開発向け） |

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
      PMA_ARBITRARY            = "1"
      PMA_BLOWFISH_SECRET      = var.pma_blowfish_secret      # AWS Secrets Manager などから取得
      CLOUDFRONT_ORIGIN_SECRET = var.cloudfront_origin_secret # AWS Secrets Manager などから取得
    }
  }
}
```

`PMA_BLOWFISH_SECRET` および `CLOUDFRONT_ORIGIN_SECRET` は AWS Secrets Manager または SSM Parameter Store（SecureString）で管理し、Terraform `var` や Lambda の環境変数として注入することを推奨します。

## Directory Structure

- [`src/`](src/) - コンテナイメージのソース
  - [`Dockerfile`](src/Dockerfile) - Lambda Web Adapter を組み込んだ phpMyAdmin イメージ
  - [`config.user.inc.php`](src/config.user.inc.php) - phpMyAdmin SSL設定
  - [`docker-compose.yml`](src/docker-compose.yml) - ローカル開発用 docker-compose
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) - ECR Private / GHCR へのイメージ Push ワークフロー
- [`ecr-terraform/`](ecr-terraform/) - ECR Private リポジトリと GitHub Actions OIDC ロールの Terraform
- [`example-terraform/`](example-terraform/) - Lambda + CloudFront デプロイ例の Terraform

## Setup

### 1. ECR Private リポジトリの作成

```bash
cd ecr-terraform
terraform init
terraform apply -var="region=ap-northeast-1"
```

`github_actions_role_arn` と `repository_uri` の出力値を控えておきます。

### 2. GitHub Secrets の設定

| Secret | 説明 |
|--------|------|
| `AWS_ROLE_ARN` | ecr-terraform で作成した GitHub Actions IAM ロール ARN |

| Variable | 説明 |
|----------|------|
| `AWS_REGION` | ECR Private を作成したリージョン (例: `ap-northeast-1`) |
| `ECR_REPOSITORY_URI` | ecr-terraform の `repository_uri` 出力値 |

### 3. イメージの Push

`main` ブランチへの push または `v*.*.*` タグの作成で自動的にイメージが ECR Private と GHCR へ Push されます。

### 4. Lambda へのデプロイ

AWS Lambda は **ECR Public** のイメージと **ECR pull through cache** のイメージを直接実行できません。  
`public.ecr.aws/...` や `xxxxxxxxxxxx.dkr.ecr.<region>.amazonaws.com/ecr-public/...` を `image_uri` に指定すると、以下のようなエラーになることがあります。

```text
InvalidParameterValueException: The image manifest, config or layer media type for the source image is not supported.
```

そのため、このリポジトリでは最初から Lambda と **同じリージョンの private ECR** に Push する構成にしています。`ecr-terraform` の `region` を Lambda のリージョンに合わせ、ワークフローでその `repository_uri` へ Push してください。

```bash
cd example-terraform
terraform init
terraform apply \
  -var="region=ap-northeast-1" \
  -var="image_uri=<account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest"
```

### セキュアな設定例

`pma_blowfish_secret` と `cloudfront_origin_secret` を必ず設定してください。前者は Cookie セッションの AES-256 暗号化キー、後者は CloudFront ↔ Lambda 間のアクセス制御シークレットです。

```bash
terraform apply \
  -var="image_uri=<account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest" \
  -var='pma_blowfish_secret=<32文字以上のランダム文字列>' \
  -var='cloudfront_origin_secret=<32文字以上の別のランダム文字列>'
```

> **推奨**: 両シークレットはバージョン管理から除外した `terraform.tfvars` または AWS Secrets Manager / SSM Parameter Store (SecureString) で管理してください。

```hcl
# terraform.tfvars (.gitignore に追加してバージョン管理対象外にすること)
pma_blowfish_secret      = "your-random-32-char-secret-here!!"
cloudfront_origin_secret = "another-random-32-char-secret!!!"
```

## Example

- [`src/docker-compose.yml`](src/docker-compose.yml): ローカル開発用 docker-compose の例
- [`example-terraform/`](example-terraform/): AWS Lambda + CloudFront にホスティングする Terraform コードの例
