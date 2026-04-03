# php-my-admin-lambda-web-adapter

[phpmyadmin-with-basic-auth](https://github.com/7474/phpmyadmin-with-basic-auth) を [AWS Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) で動作させるための構成です。

## Usage

ベースイメージの設定に加えて以下の環境変数を指定することでBASIC認証を設定できます。

- `BACIC_AUTH_USER`
- `BACIC_AUTH_PASSWORD`

また `PMA_SSL` 環境変数に `1` を設定することでSSL/TLS設定を有効にしてサーバに接続するようになります。
PlanetScaleなどのDBaaSに接続する際に設定します。

コンテナは **8080** ポートでリッスンします (Lambda Web Adapter のデフォルトポート)。

## Architecture

```
CloudFront (CDN) → Lambda Function URL → Lambda (phpMyAdmin + Lambda Web Adapter)
```

- **Lambda Web Adapter**: Lambda 呼び出しを HTTP リクエストに変換してコンテナ内の Apache へ転送します。
- **CloudFront**: CDN として Lambda Function URL の前段に配置します。

## Directory Structure

- [`src/`](src/) - コンテナイメージのソース
  - [`Dockerfile`](src/Dockerfile) - Lambda Web Adapter を組み込んだ phpMyAdmin イメージ
  - [`basic-auth.conf`](src/basic-auth.conf) - Apache BASIC認証設定
  - [`config.user.inc.php`](src/config.user.inc.php) - phpMyAdmin SSL設定
  - [`docker-entrypoint-with-basic-auth.sh`](src/docker-entrypoint-with-basic-auth.sh) - エントリポイントスクリプト
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
  -var="image_uri=<account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/phpmyadmin-lambda-adapter:latest" \
  -var="basic_auth_password=<password>"
```

## Example

- [`src/docker-compose.yml`](src/docker-compose.yml): ローカル開発用 docker-compose の例
- [`example-terraform/`](example-terraform/): AWS Lambda + CloudFront にホスティングする Terraform コードの例
