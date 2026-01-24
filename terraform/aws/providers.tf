terraform {
  required_version = ">= 1.3.0"
}

# Default provider (required, mostly unused)
provider "aws" {
  region = "us-east-1"
}

# --- US REGION POOL ---

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "use2"
  region = "us-east-2"
}

provider "aws" {
  alias  = "usw1"
  region = "us-west-1"
}

provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
}
