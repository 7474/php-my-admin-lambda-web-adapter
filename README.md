# php-my-admin-lambda-web-adapter

[phpmyadmin-with-basic-auth](https://github.com/7474/phpmyadmin-with-basic-auth) を [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) で動作させるための構成です。

## Usage

`PMA_SSL` 環境変数に `1` を設定することで SSL/TLS 設定を有効にしてサーバに接続するようになります。
PlanetScale などの DBaaS に接続する際に設定します。

コンテナは `8080` ポートでリッスンします (Lambda Web Adapter のデフォルトポート)。

## Architecture

```
CloudFront (CDN) → Lambda Function URL → Lambda (phpMyAdmin + Lambda Web Adapter)
```

- **Lambda Web Adapter**: Lambda 呼び出しを HTTP リクエストに変換してコンテナ内の Apache へ転送します。
- **CloudFront**: CDN として Lambda Function URL の前段に配置します。

## Notes

1. **VPCアクセス（Lambda VPC 配置時）**
   - `subnet_ids` と `security_group_ids` を指定することで Lambda を VPC 内に配置し、プライベートサブネットの RDS / Aurora に接続できます。
   - Lambda を VPC 内に配置すると、外部インターネットへのアウトバウンド通信がデフォルトでブロックされます。外部の DBaaS（PlanetScale など）に接続する場合は、以下の手順で VPC に NAT Gateway を設定してください：
     1. Internet Gateway を持つパブリックサブネットを作成
     2. そのサブネットに NAT Gateway を配置
     3. Lambda が使用するプライベートサブネットのルートテーブルに `0.0.0.0/0 → NAT Gateway` のルートを追加
   - VPC 内の RDS/Aurora にのみ接続する場合は NAT Gateway 不要です。

2. **Lambda 読み取り専用ファイルシステム**

   Lambda のコンテナ実行環境ではルートファイルシステムが読み取り専用にマウントされます。実行時に書き込めるのは `/tmp` のみです。この制約への対処として、以下の設定が Dockerfile に組み込まれています：

   | 対象 | デフォルトパス（変更前） | Lambda 向け変更後 |
   |------|------|------|
   | Apache PID ファイル | `/var/run/apache2/apache2.pid` | `/tmp/apache2.pid` |
   | Apache ロック/Mutex ディレクトリ | `/var/lock/apache2` | `/tmp/apache2-locks` |
   | PHP セッション保存先 | `/var/lib/php/sessions/` | `/tmp` |
   | phpMyAdmin TempDir | `/var/www/html/tmp/` | `/tmp/phpmyadmin` |
   | `config.secret.inc.php` | エントリポイントが実行時に生成 | Dockerfile でビルド時に生成済み |

   コールドスタートごとに `/tmp` は空の状態でマウントされるため、必要なサブディレクトリ（`/tmp/apache2-locks`、`/tmp/phpmyadmin`）はエントリポイント内で `mkdir -p` により作成しています。

   また、上流イメージのエントリポイントには起動時に `chgrp www-data /etc/phpmyadmin/config.secret.inc.php` を実行するコードが含まれており、読み取り専用ファイルシステム上では `EPERM` で失敗します。このリポジトリではカスタムエントリポイント（`docker-entrypoint.sh`）でその行を除去し、`config.secret.inc.php` をビルド時に生成することで問題を回避しています。

3. **Apache ユーザー名解決（AH00543）**

   Lambda の一部実行環境では `getpwnam("www-data")` が NULL を返し、Apache が以下のエラーで起動に失敗します：

   ```text
   AH00543: httpd: bad user name www-data
   ```

   これを回避するため、Dockerfile では Apache ワーカープロセスをユーザー名ではなく数値 UID/GID（`#33`）で実行しています：

   ```dockerfile
   ENV APACHE_RUN_USER=#33 \
       APACHE_RUN_GROUP=#33
   ```

4. **イメージアーキテクチャ（amd64 のみ）**

   `phpmyadmin/phpmyadmin` のベースイメージは `linux/amd64` のみで公開されています。`linux/arm64` 向けにビルドしようとすると QEMU が ELF バイナリを実行できず、以下のようなエラーになります：

   ```text
   .buildkit_qemu_emulator: /bin/sh: Invalid ELF image for this architecture
   WARNING: InvalidBaseImagePlatform: Base image phpmyadmin/phpmyadmin:5.2.3 was pulled with
     platform "linux/amd64", expected "linux/arm64"
   ```

   そのため、このリポジトリのビルドワークフローは `linux/amd64` のみを対象としています。AWS Graviton (arm64) インスタンスタイプの Lambda では動作しません。

5. **Docker イメージビルド時の OCI メディアタイプ問題**

   `docker/build-push-action` v4 以降はデフォルトで Provenance Attestation（`provenance: true`）を有効にしており、OCI イメージインデックス形式のマニフェストが生成されます。ECR がこの形式を拒否する場合があるため、ビルドワークフローでは `provenance: false` を明示的に指定しています：

   ```yaml
   - uses: docker/build-push-action@...
     with:
       provenance: false
   ```

6. **Lambda のタイムアウト・メモリ設定**

   phpMyAdmin はコールドスタート時の初期化に時間がかかる場合があります。`example-terraform` ではデフォルト値として以下を設定しています：

   | 設定 | 値 |
   |------|------|
   | タイムアウト | 30 秒 |
   | メモリサイズ | 512 MB |

   利用状況に応じて調整してください。

### アクセス制御について

Lambda Function URL はパブリックに公開されています。直接アクセスを防ぐために、CloudFront とLambda の両側で多層防御を実装しています。

#### 仕組み

```
CloudFront → (X-Origin-Verify: <secret>) → Lambda Function URL → PHP (auto_prepend_file) → Apache → phpMyAdmin
                                                                  ↑
                                              ヘッダが一致しない場合 403 を返す
```

1. CloudFront がオリジンへリクエストを転送する際に `X-Origin-Verify` ヘッダにシークレット値を付加します（`cloudfront_origin_secret` variable）。
2. PHP の `auto_prepend_file`（[`cookie-session-handler.php`](src/cookie-session-handler.php)）が `CLOUDFRONT_ORIGIN_SECRET` 環境変数と照合し、一致しない場合は HTTP 403 を返します。
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
| `SESSION_SECRET` | × | `PMA_BLOWFISH_SECRET` のフォールバック。両方とも未設定の場合はファイルセッション（`/tmp`）にフォールバック |
| `PMA_SESS_DEBUG` | × | `1` に設定するとセッションハンドラーのデバッグログを `error_log` に出力します（トラブルシュート用） |

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
  - [`config.user.inc.php`](src/config.user.inc.php) - phpMyAdmin SSL設定 & TempDir 設定
  - [`cookie-session-handler.php`](src/cookie-session-handler.php) - Cookie ベースのセッションハンドラー & オリジン検証
  - [`docker-entrypoint.sh`](src/docker-entrypoint.sh) - カスタムエントリポイント（Lambda の読み取り専用ファイルシステム対応）
  - [`docker-compose.yml`](src/docker-compose.yml) - ローカル開発用 docker-compose
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) - ECR Private / GHCR へのイメージ Push ワークフロー
- [`.github/dependabot.yml`](.github/dependabot.yml) - 依存関係の自動更新設定
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

### 2. GitHub Variables の設定

| Variable | 説明 |
|----------|------|
| `AWS_ROLE_ARN` | ecr-terraform で作成した GitHub Actions IAM ロール ARN |
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
