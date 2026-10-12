// Every PoUW-ZK repository that has a Jenkinsfile gets its own multibranch job.
// A build starts on push and PR (GitHub App webhook) or manually in the UI.
//
// Jenkins does not build PRs from forks: the repositories are public and
// foreign code would run on our server. To get Jenkins on your branch, push it to PoUW-ZK.
organizationFolder('PoUW-ZK') {
    displayName('PoUW-ZK')
    description('PoUW-ZK repositories that have a Jenkinsfile')
    organizations {
        github {
            repoOwner('PoUW-ZK')
            apiUri('https://api.github.com')
            credentialsId('github-app')
            traits {
                gitHubBranchDiscovery {
                    // branches that are not PRs
                    strategyId(1)
                }
                gitHubPullRequestDiscovery {
                    // PR merged with target branch
                    strategyId(1)
                }
            }
        }
    }
    projectFactories {
        workflowMultiBranchProjectFactory {
            scriptPath('Jenkinsfile')
        }
    }
    orphanedItemStrategy {
        discardOldItems {
            daysToKeep(7)
        }
    }
    triggers {
        periodicFolderTrigger {
            interval('1d')
        }
    }
}
