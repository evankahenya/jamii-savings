// Runs the pipeline once on Jenkins' first start (JAMII_AUTO_BUILD=false to disable)
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
    // builds queued before startup completes are discarded
    while (jenkins.initLevel != InitMilestone.COMPLETED) {
        sleep(2000)
    }
    sleep(5000)

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
