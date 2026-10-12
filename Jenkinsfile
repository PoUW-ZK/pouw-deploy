// Whole-network test: services are built from main of their repositories,
// started in a test copy of the network and run through the tests in e2e/.
// Runs on push and PR, every evening on main (from scratch, without Docker
// cache) and manually via "Build Now". Individual test results are in Tests
// on the build page, service commits in the build description.
//
// After successful tests, the evening build of main deploys the same versions
// to staging. If tests or the deploy fail, staging stays on the previous
// version and an e-mail goes to NOTIFY_EMAIL (main only, PRs show on GitHub).
pipeline {
    agent { label 'docker' }

    options {
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    environment {
        // Two builds on one agent must not share a compose project or images
        TEST_PROJECT = "pouw-test-${env.EXECUTOR_NUMBER}"
        IMAGE_TAG = "ci-${env.EXECUTOR_NUMBER}"
        NOTIFY_EMAIL = 'xmeredov@stuba.sk'
    }

    triggers {
        cron(env.BRANCH_NAME == 'main' ? 'TZ=Europe/Bratislava\nH 21 * * *' : '')
    }

    stages {
        stage('Config check') {
            steps {
                sh 'make check'
            }
        }
        stage('Build services') {
            environment {
                NO_CACHE = "${currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause') ? '1' : ''}"
            }
            steps {
                sh 'make images'
                script {
                    currentBuild.description = readFile('build/versions.txt').trim()
                }
            }
        }
        stage('Network tests') {
            steps {
                sh 'make test'
            }
        }
        stage('Deploy to staging') {
            when {
                branch 'main'
                triggeredBy 'TimerTrigger'
            }
            steps {
                withCredentials([usernamePassword(credentialsId: 'github-app',
                        usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
                    sh './scripts/staging-deploy.sh "$GIT_COMMIT"'
                }
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'reports/*.xml'
            archiveArtifacts artifacts: 'build/versions.txt', allowEmptyArchive: true
        }
        // both FAILURE and ABORTED
        unsuccessful {
            sh 'docker compose -p $TEST_PROJECT logs --no-color --tail=300 > logs.txt || true'
            archiveArtifacts artifacts: 'logs.txt', allowEmptyArchive: true
            script {
                if (env.BRANCH_NAME == 'main') {
                    emailext to: env.NOTIFY_EMAIL,
                        subject: '[PoUW Jenkins] FAILED: ${PROJECT_NAME} #${BUILD_NUMBER}',
                        body: 'Build failed, staging stays on the previous version.\n\n' +
                            '${BUILD_URL}\n\nService commits:\n' + (currentBuild.description ?: '-') +
                            '\n\nTests: ${TEST_COUNTS, var="fail"} failed out of ${TEST_COUNTS, var="total"}\n' +
                            '${FAILED_TESTS, showStack=false, maxTests=20}\n\n' +
                            'End of log:\n${BUILD_LOG, maxLines=50}'
                }
            }
        }
        fixed {
            script {
                if (env.BRANCH_NAME == 'main') {
                    emailext to: env.NOTIFY_EMAIL,
                        subject: '[PoUW Jenkins] FIXED: ${PROJECT_NAME} #${BUILD_NUMBER}',
                        body: 'Build of main passed after a previous failure.\n\n${BUILD_URL}\n\n' +
                            'Service commits:\n' + (currentBuild.description ?: '-')
                }
            }
        }
        // cleanup runs after the other post blocks, otherwise the logs would already be gone
        cleanup {
            sh 'make test-down || true'
            sh 'docker image prune -f || true'
            cleanWs()
        }
    }
}
