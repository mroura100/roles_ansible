#!/bin/bash
# was.generic.sh WAS8.5
# Versio was.generic.sh: 1

umask 0022

ACCIO=$(basename $0 | awk -F. '{print $2}')
INSTANCIA=$(basename $0 | awk -F. '{print $1}')
HOSTNAME=$(hostname -s)
SERVEI=$(echo $HOSTNAME | cut -c 3,4)
NUM_MAQ=$(echo $HOSTNAME | cut -c 8)
NUM_CLU=$(echo $INSTANCIA | cut -c 7)
CLUSTER="clugct${NUM_CLU}"
DIRNAME=$(dirname $0)
USUARI=`whoami`

#NYAPA perque hi han maquines amb WAS que comencen amb lu i n'hi ha que comencen amb lw
LLETRA=$(echo $HOSTNAME | cut -c 2)

ENTORN_CURT=$(echo $HOSTNAME | cut -c 5)
if [[ $ENTORN_CURT == "t" ]]; then
        ENTORN="pre"
elif [[ $ENTORN_CURT == "x" ]]; then
        ENTORN="pro"
elif [[ $ENTORN_CURT == "i" ]];then
        ENTORN="int"
else
        echo "Entorn no contemplat"
        exit 1
fi


LOGS="/var/log/${ENTORN}/$LLETRA${SERVEI}/websphere90"
LOGS_APPSERVER="$LOGS/appServer"
LOGS_DMGR="$LOGS/dmgr"

USER=was

TIMEOUT=300
DATA=`date +%d-%m-%Y_%H-%M`
CELL=`ls /opt/IBM/WAS90/profiles/${HOSTNAME}/config/cells/ | grep -v plugin`

PATH_WAS_INSTALL=/opt/IBM/WAS90/AppServer
PATH_WAS_PROFILES=/opt/IBM/WAS90/profiles

APPSERVER_PROFILE=${PATH_WAS_PROFILES}/${HOSTNAME}
APPSERVER_SERVERINDEX=$APPSERVER_PROFILE/config/cells/$CELL/nodes/${HOSTNAME}/serverindex.xml

DMGR_PROFILE=`find $PATH_WAS_PROFILES -maxdepth 1 -name 'dmgr' -type d`
DMGR_NAME=`echo $DMGR_PROFILE | awk -F"/" '{print $NF}'`

DMGR_SOAP_HOST=$( hostname -s )
DMGR_SOAP_PORT="8879"

WSADMIN=$PATH_WAS_INSTALL/bin/wsadmin.sh

WSSN=localhost
WSSP=8001

#Logs on s'escriura la sortida dels status (nodeagent/dmgr)
LOG_STATUS_NODEAGENT=$LOGS_APPSERVER/nodeagent/nodeagent.status.log
LOG_STATUS_DMGR=$LOGS_DMGR/dmgr/dmgr.status.log

if [[ "$DMGR_PROFILE" != "" ]] ; then
        DMGR_NODE=`find $DMGR_PROFILE/config/cells/$CELL/nodes/ -name "dmgr*" -type d -prune | awk -F"/" '{print $NF}'`
        DMGR_SERVERINDEX=$DMGR_PROFILE/config/cells/$CELL/nodes/${DMGR_NODE}/serverindex.xml
        DMGR_HOST=$(grep $HOSTNAME $DMGR_SERVERINDEX | tail -1 | awk -F\" '{ print $4 }' | awk -F. '{ print $1}')
fi


# Comprova si existeix el proc▒s de la inst▒ncia ($INSTANCIA)
find_appServer() {
        ps -fea | grep -v grep | egrep -q "${PATH_WAS_INSTALL}.*${INSTANCIA}"
        return $?
}

#Comprova si existeix el dmgr
find_dmgr() {
        ps -efa | grep -v grep | egrep -q "${CELL}.*dmgr"
        return $?
}

#Retorna el PID del dmgr si existeix
find_dmgr_pid() {
        ps -efa | grep -v grep | egrep "${CELL}.*dmgr$" | awk '{print $2}'
}

#Retorna el PID del appServer si existeix
find_appServer_pid() {
        ps -efa | grep -v grep | egrep "${PATH_WAS_INSTALL}.*${INSTANCIA}" | awk '{print $2}'
}

#Comprova si existeix el perfil del dmgr en el host local
check_dmgr_host() {
        if [[ "$DMGR_PROFILE" == "" ]] ; then
                echo "No existeix cap perfil de dmgr en el servidor"
                exit 0
        fi
        if [ "$DMGR_HOST" != "$HOSTNAME" ]; then
                echo "El $DMGR_NAME est▒ configurat en el servidor $DMGR_HOST";
                exit 0
        fi
}

#Comprova el status del dmgr, es connecta per wsadmin al dmgr i executa una comanda
#te un timeout de 5 minuts
dmgr_status() {
        TMPFILE="/tmp/tmpStatusDmgr_$$.exp"
        cat << _EOF > $TMPFILE

#!/usr/bin/expect
set wsadmin "$WSADMIN"
set timeout 300
log_user 0
spawn \$wsadmin -lang jython -c "AdminConfig.list('Server')"
expect {
        "Error" {
                puts "CRITICAL: No es pot connectar al DMGR"
                exit 1
        }
        timeout {
                puts "CRITICAL: No es pot connectar al dmgr(Timeout 5mins)"
                exit 1
        }
}
puts "OK: dmgr en estat correcte"
exit 0
_EOF
        if [ $USUARI == was ]; then
                /usr/bin/expect -f $TMPFILE
        else
                su - $USER -c "/usr/bin/expect -f $TMPFILE"
        fi
        RES=$?
        rm $TMPFILE
        return $RES
}

#Comprova si el nodeagent est▒ sincronitzat
nodeagent_status() {
        TMPFILE="/tmp/tmpStatusNodeagent_$$.py"
        cat << _EOF > $TMPFILE

NodeSync = AdminControl.completeObjectName('type=NodeSync,node=' + '${HOSTNAME}' + ',*')
res = AdminControl.invoke(NodeSync, 'isNodeSynchronized')
waits = 4
if (res != "true"):
        print "isNodeSynchronized: " + res
        print "requestSync: " + AdminControl.invoke(NodeSync, 'requestSync')
        result = AdminControl.invoke(NodeSync, 'getResult')
        while ( result.find("In Progress") != -1 and waits > 0 ):
                time.sleep(60)
                waits = waits - 1
                result = AdminControl.invoke(NodeSync, 'getResult')
else:
                print "isNodeSynchronized: " + res
_EOF
        if [ $USUARI == was ]; then
                $WSADMIN -lang jython -f $TMPFILE 2>&1 | tee -a $LOG_STATUS_NODEAGENT | grep -q 'isNodeSynchronized: true'
        else
                su - $USER -c "$WSADMIN -lang jython -f $TMPFILE 2>&1 | tee -a $LOG_STATUS_NODEAGENT | grep -q 'isNodeSynchronized: true'"
        fi
        RES=$?
        rm $TMPFILE
        if [ $RES -eq 0 ]; then
                echo "OK: Instancia $INSTANCIA en estat correcte"
                exit 0
        else
                echo "WARNING: Instancia $INSTANCIA no sincronitzada"
                exit 1
        fi
}

#Comprova el stat d'una inst▒ncia executant un CURL contr el Alive
appServer_status() {
        SERVER_PORT=$(awk -v INST=$INSTANCIA 'BEGIN { FS="serverEntries"; RS="/serverEntries"; } $0 ~ INST { print }' $APPSERVER_SERVERINDEX | awk 'BEGIN { FS="specialEndpoints"; RS="/specialEndpoints"; } /"WC_defaulthost"/ { print }' | grep port | awk -F\" '{ print $6 }')
        CURL_OPTIONS="-A Monitoritzacio_WAS --connect-timeout 8 --max-time 9 -H  \$WSSN:$WSSN -H \$WSSP:$WSSP "
        CURL_URL="http://localhost:${SERVER_PORT}/${CLUSTER}/Alive/"
        CURL="$( which curl ) -q -s"
        $CURL $CURL_OPTIONS $CURL_URL 2>&1 | grep -q "Instancia OK"
        return $?
}



was_start() {
        sleep 1
        if [[ "$INSTANCIA" == "dmgr" ]] ; then
                check_dmgr_host
                find_dmgr
                if [ $? -eq 0 ]; then
                        echo "El $DMGR_NAME ja est▒ arrencat."
                        exit 1
                fi
                dmgr_status
                if [ $? -eq 0 ]; then
                        echo "El $DMGR_NAME ha d'estar aturat, exit 0."
                        exit 1
                fi
        else
                find_appServer
                if [ $? -eq 0 ]; then
                        echo "El $INSTANCIA ja est▒ arrencat."
                        exit 1
                fi
                appServer_status
                if [ $? -eq 0 ]; then
                        echo "El $INSTANCIA ha d'estar aturat, exit 0."
                        exit 0
                fi
        fi

        case "$INSTANCIA" in
        dmgr)
                echo "Arrencant dmgr ..."
                if [ $USUARI == was ]; then
                        $DMGR_PROFILE/bin/startManager.sh -timeout $TIMEOUT
                else
                        su - $USER -c "$DMGR_PROFILE/bin/startManager.sh -timeout $TIMEOUT"
                fi
                ESTAT=${PIPESTATUS[0]}
                find_dmgr
                PROCES=$?
                ;;

        nodeagent)
                echo "Arrencant nodeagent"
                if [ $USUARI == was ]; then
                        $APPSERVER_PROFILE/bin/startNode.sh -timeout $TIMEOUT
                else
                        su - $USER -c "$APPSERVER_PROFILE/bin/startNode.sh -timeout $TIMEOUT"
                fi
                ESTAT=${PIPESTATUS[0]}
                find_appServer
                PROCES=$?
                ;;

        "$LLETRA"*)
                echo "Arrencant $INSTANCIA"
                if [ $USUARI == was ]; then
                        $APPSERVER_PROFILE/bin/startServer.sh $INSTANCIA -timeout $TIMEOUT
                else
                        su - $USER -c "$APPSERVER_PROFILE/bin/startServer.sh $INSTANCIA -timeout $TIMEOUT"
                fi
                ESTAT=${PIPESTATUS[0]}
                find_appServer
                PROCES=$?
                ;;

        *)
                echo "Invalid server"
                exit 1
                ;;
        esac

        if [[ $ESTAT -eq 0 ]] && [[ $PROCES -eq 0 ]]; then
                echo "OK Instancia $INSTANCIA arrencada correctament" ; exit 0
        elif [[ $ESTAT -ne 0 ]] && [[ $PROCES -eq 0 ]]; then
                echo "WARNING: Instancia $INSTANCIA no ha arrencat despr▒s de $TIMEOUT segons. Comprovi el seu estat."; exit 1
        else
                echo "CRITICAL: Instancia $INSTANCIA no ha arrencat. El proc▒s ha mort."; exit 1
        fi
        echo
}

##
## STOP
##

was_stop() {
        sleep 1
        if [[ "$INSTANCIA" == "dmgr" ]] ; then
                check_dmgr_host
                find_dmgr
        else
                find_appServer
        fi
        if [ $? -ne 0 ]; then
                echo "OK Instancia $INSTANCIA esta aturada"
                exit 0
        fi

        case "$INSTANCIA" in
        dmgr)
                echo "Aturant dmgr ..."
                if [ $USUARI == was ]; then
                        $DMGR_PROFILE/bin/stopManager.sh -timeout $TIMEOUT
                else
                        su - $USER -c "$DMGR_PROFILE/bin/stopManager.sh -timeout $TIMEOUT"
                fi
                sleep 10
                find_dmgr
                PROCES=$?
                PID=$(find_dmgr_pid)
                ;;

        nodeagent)
                echo "Aturant nodeagent ..."
                if [ $USUARI == was ]; then
                        $APPSERVER_PROFILE/bin/stopNode.sh -timeout $TIMEOUT
                else
                        su - $USER -c "$APPSERVER_PROFILE/bin/stopNode.sh -timeout $TIMEOUT"
                fi
                sleep 10
                find_appServer
                PROCES=$?
                PID=$(find_appServer_pid)
                ;;

        "$LLETRA"*)
                echo "Aturant $INSTANCIA ..."
                if [ $USUARI == was ]; then
                        $APPSERVER_PROFILE/bin/stopServer.sh $INSTANCIA -timeout $TIMEOUT
                else
                        su - $USER -c "$APPSERVER_PROFILE/bin/stopServer.sh $INSTANCIA -timeout $TIMEOUT"
                fi
                sleep 10
                find_appServer
                PROCES=$?
                PID=$(find_appServer_pid)
                ;;

        *)
                echo "Invalid server"
                exit 1
                ;;
        esac

        if [[ $PROCES -ne 0 ]] ; then
                echo "OK Instancia $INSTANCIA aturada correctament." ; exit 0
        else
                if [ ! -z "$PID" ]; then
                        kill -3 $PID > /dev/null 2>&1
                        sleep 10
                        kill -9 $PID > /dev/null 2>&1
                        echo "OK Instancia $INSTANCIA aturada de manera for▒ada" ; exit 1
                else
                        echo "No troba el PID de $INSTANCIA"
                        exit 1
                fi
        fi
        echo
}

##
## STATUS
##


was_status() {
        case "$INSTANCIA" in
        dmgr)
                find_dmgr
                if [ $? -ne 0 ]; then
                        echo "CRITICAL: $DMGR_NAME aturat"
                        exit 1
                fi
                #echo "INFO: Aquest script pot tardar fins a 5 minuts"
                dmgr_status
                ;;

        nodeagent)
                find_appServer
                if [ $? -ne 0 ] ; then
                        echo "CRITICAL: Instancia $INSTANCIA aturada"
                        exit 1
                fi
                #echo "INFO: Aquest script pot tardar fins a 5 minuts"
                nodeagent_status
                ;;

        "$LLETRA"*)
                appServer_status
                if [ $? -eq 0 ]; then
                        echo "OK: Instancia $INSTANCIA en estat correcte"
                        exit 0
                else
                        find_appServer
                        if [[ $? -eq 1 ]] ; then
                                echo "CRITICAL: Instancia $INSTANCIA aturada" ; exit 1
                        else
                                echo "CRITICAL: Instancia $INSTANCIA en estat ALERTA" ; exit 1
                        fi
                fi
                ;;
        *)
                echo "Invalid server"
                exit 1
                ;;
        esac
}

##
## SERVEI
##

was_servei() {
        echo
        if /usr/bin/curl -q -A "Monitoritzacio_WAS" --connect-timeout 8 --max-time 9 http://${WSSN}:${WSSP}/${CLUSTER}/Alive/ 2> /dev/null | grep -q "Test Servlet" ; then
                echo "OK servei ${CLUSTER} en estat correcte"
                exit 0
        else
                echo "CRITICAL: servei ${CLUSTER} no correcte"
                exit 1
        fi
}

##
## MAIN
##

case "$ACCIO" in
start)
        was_start
        ;;

stop)
        was_stop
        ;;

status)
        was_status
        ;;

servei)
        was_servei
        ;;

*)
        echo "Invalid parameter"
        exit 1
        ;;
esac