// =====================================================================
// Jamii Savings - ONE pipeline for ALL the APIs.
//
// The APIs it handles = the folders in Jamii_WSO2_Project/apim-apis/
// (AccountBalanceAPI, CustomersAPI, LoansAPI).
// Adding an API = adding a folder there; nothing in this file changes.
//
//   Validate -> Build MI CAR -> Test -> Package APIM APIs
//            -> Deploy: dev -> [approve] -> Deploy: uat -> [approve] -> Deploy: prod
//
// Each deploy is all-or-nothing (see ci/scripts/deploy.sh): if the MI CApp or ANY
// of the APIs fails to deploy or fails its smoke test, everything already changed
// in that environment is rolled back and the build fails.
// Environment settings live in ci/environments/<env>.properties.
// =====================================================================

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()            // never two deployments at the same time
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
    }

    parameters {
        choice(name: 'DEPLOY_UP_TO', choices: ['dev', 'uat', 'prod'],
               description: 'Promote dev -> uat -> prod, stopping at this environment')
    }

    environment {
        MI_PROJECT = 'Jamii_WSO2_Project'
    }

    stages {
        stage('Validate') {
            steps {
                sh 'bash ci/scripts/validate.sh'
            }
        }

        stage('Build MI CAR') {
            steps {
                dir(env.MI_PROJECT) {
                    sh 'mvn -B clean install -Dmaven.test.skip=true'
                }
            }
        }

        stage('Test') {
            steps {
                // Synapse unit tests from src/test/wso2mi (none written yet - the step reports that).
                // Functional checks against the deployed APIs run as smoke tests in each Deploy stage.
                dir(env.MI_PROJECT) {
                    sh 'mvn -B test'
                }
            }
        }

        stage('Package APIM APIs') {
            steps {
                sh 'bash ci/scripts/package-apis.sh'
                archiveArtifacts artifacts: "${env.MI_PROJECT}/target/*.car, dist/apis/**", fingerprint: true
            }
        }

        stage('Deploy: dev') {
            steps { script { deployTo('dev') } }
        }

        stage('Approve: uat') {
            when { expression { params.DEPLOY_UP_TO in ['uat', 'prod'] } }
            steps { input message: 'dev is green. Promote to UAT?', ok: 'Deploy to UAT' }
        }
        stage('Deploy: uat') {
            when { expression { params.DEPLOY_UP_TO in ['uat', 'prod'] } }
            steps { script { deployTo('uat') } }
        }

        stage('Approve: prod') {
            when { expression { params.DEPLOY_UP_TO == 'prod' } }
            steps { input message: 'UAT is green. Promote to PRODUCTION?', ok: 'Deploy to prod' }
        }
        stage('Deploy: prod') {
            when { expression { params.DEPLOY_UP_TO == 'prod' } }
            steps { script { deployTo('prod') } }
        }
    }

    post {
        success { echo "Deployed MI CApp + all APIs up to '${params.DEPLOY_UP_TO}'." }
        failure { echo 'Pipeline FAILED. If a Deploy stage failed, its log shows the rollback that was done.' }
    }
}

// Deploys the already-built artifacts to one environment, using its settings file.
// The same artifacts (built once, above) are promoted through every environment.
def deployTo(String envName) {
    def cfg = readProperties file: "ci/environments/${envName}.properties"
    if (cfg.ENABLED != 'true') {
        echo "'${envName}' is a placeholder (ENABLED=false in ci/environments/${envName}.properties) - nothing deployed."
        return
    }
    withCredentials([
        usernamePassword(credentialsId: cfg.APIM_CREDENTIALS_ID, usernameVariable: 'APIM_USER', passwordVariable: 'APIM_PASS'),
        usernamePassword(credentialsId: cfg.MI_CREDENTIALS_ID,   usernameVariable: 'MI_USER',   passwordVariable: 'MI_PASS'),
    ]) {
        withEnv([
            "TARGET_ENV=${envName}",
            "APIM_URL=${cfg.APIM_URL}",
            "GATEWAY_URL=${cfg.GATEWAY_URL}",
            "MI_MGMT_URL=${cfg.MI_MGMT_URL}",
            "MI_URL=${cfg.MI_URL}",
        ]) {
            sh 'bash ci/scripts/deploy.sh'
        }
    }
}
