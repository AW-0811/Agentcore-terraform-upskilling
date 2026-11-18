terraform {
  backend "s3" {
    key          = "incident-triage-demo/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
}
