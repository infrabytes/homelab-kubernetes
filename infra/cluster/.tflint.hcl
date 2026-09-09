# Docs: https://github.com/terraform-linters/tflint
#       https://github.com/terraform-linters/tflint-ruleset-terraform
#
# Run:              tflint --recursive
# With fixes:       tflint --recursive --fix

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_module_pinned_source" {
  enabled = false
}

rule "terraform_module_version" {
  enabled = false
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}
