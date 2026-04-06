terraform {
  backend "remote" {
    organization = "koudenpa"
    workspaces {
      name = "phpmyadmin-lambda-adapter"
    }
  }
}
