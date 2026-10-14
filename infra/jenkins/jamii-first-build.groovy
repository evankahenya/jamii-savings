// Runs when Jenkins starts. On the FIRST start (job never built) it runs the
// jamii-api-deploy pipeline once, so the APIs end up in MI + APIM without anyone
// clicking Build. Later restarts don't redeploy. Turn off with JAMII_AUTO_BUILD=false.
//
// It waits until Jenkins has fully started: a build scheduled earlier is thrown away
// when Jenkins loads its build queue. The pipeline itself waits for MI/APIM to be
// ready, so it doesn't matter if the platform is still starting.
import hudson.init.InitMilestone
import hudson.model.Cause
import hudson.model.CauseAction
import hudson.security.ACL
import jenkins.model.Jenkins
import jenkins.model.ParameterizedJobMixIn

if ((System.getenv('JAMII_AUTO_BUILD') ?: 'true') != 'true') {
    println '[jamii] JAMII_AUTO_BUILD is not true - not starting the first build'
    return
}

Thread.start('jamii-first-build') {
    def jenkins = Jenkins.get()
    while (jenkins.initLevel != InitMilestone.COMPLETED) {
        sleep(2000)
    }
    sleep(5000)   // let the configuration-as-code job setup settle

    // a background thread runs as "anonymous", which may not see jobs - act as SYSTEM
    def acl = ACL.as2(ACL.SYSTEM2)
    try {
        def job = jenkins.getItemByFullName('jamii-api-deploy')
        if (job == null) {
            println '[jamii] job jamii-api-deploy not found - nothing to start'
        } else if (job.lastBuild != null || job.isInQueue()) {
            println '[jamii] jamii-api-deploy has run before - no automatic build'
        } else {
            println '[jamii] first start: scheduling jamii-api-deploy'
            def cause = new Cause.RemoteCause('jenkins', 'First start of Jenkins - automatic deployment')
            ParameterizedJobMixIn.scheduleBuild2(job, 0, new CauseAction(cause))
        }
    } finally {
        acl.close()
    }
}
