#!/bin/bash
# as3.sh <command> (part 21): AS3 on lb-f5a (or F5U=lb-f5b), through the BIG-IP's own REST API, called on the BIG-IP itself:
#   curl to localhost:8100 (restjavad, no TLS) as the admin user. AS3 refuses anonymous requests, so restcurl's default is not enough.
#   install       copy the AS3 RPM (on the lab server in /root/as3) to the BIG-IP and install it as an iControl LX package
#   info          AS3's version (/mgmt/shared/appsvcs/info)
#   post <file>   send a declaration; prints each tenant's result (message, HTTP code, run time)
#   get           the declaration AS3 holds now
#   delete <t>    remove a tenant (partition) and everything AS3 made in it
#   plan <file>   dry run: the same POST with controls dryRun + traceResponse; prints AS3's planned changes (N new, E edit, D delete)
#   async <file>  POST ?async=true: AS3 answers at once with a task id; then poll /shared/appsvcs/task/<id> for the result
#   expanded      the held declaration with AS3's defaults filled in (?show=expanded): part 21's serviceMain
U=${F5U:-lb-f5a}; RPM=f5-appsvcs-3.56.0-10.noarch.rpm
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
on() { ssh $O admin@clab-f5-clos-dc-$U "R() { curl -s -u admin: -H Content-Type:application/json \"\$@\"; }; M=http://localhost:8100/mgmt; $*" 2>&1 | grep -v api-status; }
case $1 in
  install)
    scp -q $O /root/as3/$RPM admin@clab-f5-clos-dc-$U:/var/config/rest/downloads/ && echo "copied $RPM to $U:/var/config/rest/downloads/"
    on "R -X POST \$M/shared/iapp/package-management-tasks -d '{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$RPM\"}' > /var/tmp/as3task.json; id=\$(jq -r .id /var/tmp/as3task.json); echo \"install task \$id\";
        for i in \$(seq 40); do s=\$(R \$M/shared/iapp/package-management-tasks/\$id | jq -r .status); [ \"\$s\" = FINISHED ] || [ \"\$s\" = FAILED ] && break; sleep 3; done; echo \"task status: \$s\";
        for i in \$(seq 30); do r=\$(R \$M/shared/appsvcs/info 2>/dev/null); echo \"\$r\" | grep -q version && break; sleep 3; done; echo \"AS3 answers: \$r\"" ;;
  info)   on "R \$M/shared/appsvcs/info; echo" ;;
  post)   on "cat > /var/tmp/as3.json && R -X POST \$M/shared/appsvcs/declare -d @/var/tmp/as3.json | jq -c 'if .results then .results[] | {tenant, message, code, runTime} else {code, message, errors} end'" < "${2:?file}" ;;
  get)    on "R \$M/shared/appsvcs/declare | jq ." ;;
  delete) on "R -X DELETE \$M/shared/appsvcs/declare/${2:?tenant} | jq -c 'if .results then .results[] | {tenant, message, code, runTime} else {code, message, errors} end'" ;;
  plan)   on "cat > /var/tmp/as3.json && jq '.declaration.controls = {\"class\": \"Controls\", \"dryRun\": true, \"traceResponse\": true}' /var/tmp/as3.json > /var/tmp/as3plan.json &&
              R -X POST \$M/shared/appsvcs/declare -d @/var/tmp/as3plan.json | jq -r '.results[] | \"dryRun: \\(.dryRun)  \\(.message)\"' ;
              R -X POST \$M/shared/appsvcs/declare -d @/var/tmp/as3plan.json | jq -r '.traces | to_entries[] | select(.key | endswith(\"Diff\")) | .value[] | \"\\(.kind) \\(.path | join(\"/\"))  \\(.lhs | tostring | .[0:40]) -> \\(.rhs | tostring | .[0:40])\"'" < "${2:?file}" ;;
  async)  on "cat > /var/tmp/as3.json && id=\$(R -X POST \"\$M/shared/appsvcs/declare?async=true\" -d @/var/tmp/as3.json | jq -r .id); echo \"accepted, task \$id\";
              for i in \$(seq 40); do r=\$(R \$M/shared/appsvcs/task/\$id | jq -c '[.results[] | {tenant, message, code}]'); echo \"\$r\" | grep -q 'in progress' || break; echo 'in progress'; sleep 1; done; echo \"\$r\"" < "${2:?file}" ;;
  expanded) on "R \"\$M/shared/appsvcs/declare?show=expanded\" | jq '.f5lab_as3.web.serviceMain | {class, profileTCP, profileHTTP, persistenceMethods, snat}'" ;;
  *) echo "install | info | post <file> | get | delete <tenant> | plan <file> | async <file> | expanded"; exit 1;;
esac
