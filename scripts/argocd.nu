#!/usr/bin/env nu

# Log in to an ArgoCD server
#
# This command authenticates a user to the specified ArgoCD server using provided credentials.
#
# Usage:
#   main argocd login [--username <username>] [--server <server_url>] --password <password>
#
# Parameters:
#   --username (-u): string (optional)
#     The username for ArgoCD authentication.
#     Default: "admin"
#
#   --server (-s): string (optional)
#     The URL of the ArgoCD server to log in to.
#     Default: "argocd.verticon.com"
#
#   --password (-p): string (required)
#     The password for ArgoCD authentication.
#   NOTES:
# In order to access the server UI you have the following options:
# 2. enable ingress in the values file `server.ingress.enabled` and either
#       - Add the annotation for ssl passthrough: https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#option-1-ssl-passthrough
#       - Set the `configs.params."server.insecure"` in the values file and terminate SSL at your ingress: https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#option-2-multiple-ingress-objects-and-hosts
#
# Examples:
#   ops argocd login --server argocd.verticon.com
#   main argocd login --password mypassword
#   main argocd login --username myuser --server argocd.verticon.com --password mypassword
#
# Note:
#   This command uses the --grpc-web flag, which is useful if the ArgoCD server is behind a proxy
#   that does not support HTTP2. The command will fail if the password is not provided.
def "main argocd login" [
    --username (-u): string = "admin",
    --server (-s): string = "argocd.verticon.com",
    --password (-p): string
] {
    let password = if $password == null {
        let initial_password = (run-external "kubectl" "-n" "argocd" "get" "secret" "argocd-initial-admin-secret" "-o" "jsonpath={.data.password}" | base64 -d | str trim)
        # print $initial_password
        if $initial_password == "" {
            error make { msg: "Password is required. Please provide it using the --password flag." }
        } else {
            $initial_password
        }
    } else {
        $password
    }

    run-external "argocd" "login" $server "--username" $username "--password" $password "--grpc-web"

    print $"Logged in to ArgoCD server ($server) as ($username)"
}

# Log out from an ArgoCD server
#
# This command logs out the current user from the specified ArgoCD server.
#
# Usage:
#   main argocd logout [--server <server_url>]
#
# Parameters:
#   --server (-s): string (optional)
#     The URL of the ArgoCD server to log out from.
#     Default: "argocd.verticon.com"
#
# Example:
#   main argocd logout
#   main argocd logout --server https://argocd.example.com
#
# Note:
#   This command will remove the session token for the specified server.
#   You will need to log in again to access ArgoCD resources on this server.
def "main argocd logout" [
    --server (-s): string = "argocd.verticon.com"
] {
    run-external "argocd" "logout" $server 
    print $"Logged out of ArgoCD server ($server) "
}



# Add a GitHub repository to ArgoCD using a record of repository information
#
# This function adds a GitHub repository to ArgoCD using the provided repository details.
# It uses the ArgoCD CLI tool to perform the operation.
#
# Parameters:
#   repo_info: A record containing the following fields:
#     - github_repo: string  # The full URL of the GitHub repository
#     - github_user: string  # The GitHub username
#     - github_token: string # The GitHub personal access token for authentication
#
# Example usage:
#   main argocd add-repo {
#     github_repo: "https://github.com/username/repo.git",
#     github_user: "username",
#     github_token: "your-github-token"
#   }
#
# Note:
#   This function uses the --insecure-skip-server-verification flag with the argocd command.
#   This bypasses SSL verification and should be used with caution, only in environments
#   where you understand and accept the security implications.
#
# Returns:
#   The output of the argocd repo add command, which typically includes a success message
#   or error information if the operation fails.
def "main argocd add-repo" [
    repo_info: record<github_repo: string, github_user: string, github_token: string>
] {
    print $"argocd add repo request: ($repo_info)"
    # Extract values from the record
    let repo = $repo_info.github_repo
    let user = $repo_info.github_user
    let token = $repo_info.github_token

    
    # Add repository to ArgoCD using GitHub credentials
    argocd repo add $repo --username $user --password $token --insecure-skip-server-verification
}

# List configured repositories in ArgoCD
#
# This function executes the 'argocd repo list' command and returns the results as a structured table.
#
# Usage:
#   argocd list-repo
#
# Returns:
#   A table with columns for repository details (e.g., TYPE, NAME, REPO, INSECURE, etc.)
#
# Example:
#   argocd list-repo
#
# Note: Requires ArgoCD CLI to be installed and configured
def "main argocd list-repo" [] {
    run-external  "argocd" "repo" "list" "--output" "wide"
    | detect columns
}

# List configured applications in ArgoCD
#
# This function executes the 'argocd app list' command and returns the results as a structured table.
#
# Usage:
#   argocd list-app
#
# Returns:
#   A table with columns for application details (e.g., TYPE, NAME, REPO, INSECURE, etc.)
#
# Example:
#   argocd list-app
#
# Note: Requires ArgoCD CLI to be installed and configured
def "main argocd list-app" [] {
    run-external  "argocd" "app" "list" "--output" "wide"
    | detect columns
}