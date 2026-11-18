variable "state_bucket_name" {
  description = "Private, versioned bucket created by the bootstrap Terraform root."
  type        = string
}

variable "app_artifact_bucket_name" {
  description = "Existing S3 bucket that stores the AgentCore application ZIP."
  type        = string
}

variable "agent_runtime_arn" {
  description = "The existing AgentCore runtime managed by the application Terraform root."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organization that owns the source repository."
  type        = string
  default     = "AW-0811"
}

variable "github_repository" {
  description = "GitHub repository name used by CodeConnections."
  type        = string
  default     = "Agentcore-terraform-upskilling"
}

variable "github_branch" {
  description = "Branch whose changes can start a release plan."
  type        = string
  default     = "main"
}
