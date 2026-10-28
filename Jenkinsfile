// ShipLog pipeline: test, build, scan, push and deploy, then record the run in ShipLog itself.

// Log in to Azure as the Jenkins service principal, using credentials from the Jenkins store.
// In a team this would live in a shared library as vars/azLogin.groovy.
def azLogin() {
    withCredentials([
        usernamePassword(credentialsId: 'azure-sp', usernameVariable: 'AZ_CLIENT_ID', passwordVariable: 'AZ_CLIENT_SECRET'),
        string(credentialsId: 'azure-tenant-id', variable: 'AZ_TENANT_ID'),
        string(credentialsId: 'azure-subscription-id', variable: 'AZ_SUBSCRIPTION_ID'),
    ]) {
        // Single quotes: the shell expands the secrets, so Groovy never writes them into the command
        sh '''
            az login --service-principal --username "$AZ_CLIENT_ID" --password="$AZ_CLIENT_SECRET" --tenant "$AZ_TENANT_ID" -o none
            az account set --subscription "$AZ_SUBSCRIPTION_ID"
        '''
    }
}

pipeline {
    agent any

    triggers {
        pollSCM('H/2 * * * *') // check GitHub for new commits every 2 minutes
    }

    options {
        skipDefaultCheckout() // the Checkout stage does it explicitly
        disableConcurrentBuilds() // one deploy at a time
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        // Resource names are not secrets. IDs and the SP secret come from Jenkins credentials.
        ACR_NAME       = 'acrshiploggly65t'
        RESOURCE_GROUP = 'rg-shiplog-dev'
        CONTAINER_APP  = 'ca-shiplog-dev'
        KEY_VAULT      = 'kv-shiplog-gly65t'
        SHIPLOG_URL    = 'https://ca-shiplog-dev.whitecoast-40432c8a.canadacentral.azurecontainerapps.io'
        // A private az login for each build, deleted in post
        AZURE_CONFIG_DIR = "${WORKSPACE}/.azure"
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    env.GIT_SHA = checkout(scm).GIT_COMMIT
                    env.IMAGE = "${ACR_NAME}.azurecr.io/shiplog:${env.GIT_SHA}"
                }
            }
        }

        stage('Test') {
            steps {
                sh '''
                    python3 -m venv .venv
                    . .venv/bin/activate
                    pip install -q -r requirements-dev.txt
                    pytest -q
                '''
            }
        }

        stage('Build') {
            steps {
                sh 'docker build --build-arg APP_VERSION="$GIT_SHA" -t "$IMAGE" .'
            }
        }

        stage('Scan') {
            steps {
                // Fail on CRITICAL vulnerabilities that have a fix available
                sh 'trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 --no-progress "$IMAGE"'
            }
        }

        stage('Push') {
            steps {
                azLogin()
                sh 'az acr login --name "$ACR_NAME" && docker push "$IMAGE"'
            }
        }

        stage('Deploy') {
            steps {
                sh 'az containerapp update --name "$CONTAINER_APP" --resource-group "$RESOURCE_GROUP" --image "$IMAGE" -o none'
                // Done only when /health reports this commit, so the new revision is serving traffic
                timeout(time: 5, unit: 'MINUTES') {
                    waitUntil(initialRecurrencePeriod: 5000) {
                        sh(script: 'curl -fsS --max-time 30 "$SHIPLOG_URL/health" | grep -q "$GIT_SHA"', returnStatus: true) == 0
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                // currentResult is no longer SUCCESS if any stage failed or timed out
                env.DEPLOY_STATUS = currentBuild.currentResult == 'SUCCESS' ? 'success' : 'failure'
                env.DURATION = "${currentBuild.duration / 1000}"
                // Recording the run must never change the build result
                try {
                    azLogin()
                    def rc = sh(returnStatus: true, script: '''
                        set +x  # stop echoing commands: the API key is not a Jenkins credential, so it isn't masked
                        KEY=$(az keyvault secret show --vault-name "$KEY_VAULT" --name shiplog-api-key --query value -o tsv)
                        printf '{"service":"shiplog","commit_sha":"%s","status":"%s","duration_seconds":%s}' \
                            "$GIT_SHA" "$DEPLOY_STATUS" "$DURATION" > deploy.json
                        curl -fsS --max-time 60 -X POST "$SHIPLOG_URL/deploys" \
                            -H "X-API-Key: $KEY" -H "Content-Type: application/json" --data @deploy.json
                    ''')
                    if (rc != 0) {
                        echo "WARNING: could not record this run in ShipLog (exit code ${rc}). Build result unchanged."
                    }
                } catch (err) {
                    echo "WARNING: could not record this run in ShipLog: ${err}. Build result unchanged."
                }
            }
            sh 'az logout || true; rm -rf "$AZURE_CONFIG_DIR"'
        }
    }
}
