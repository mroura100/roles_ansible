#!/bin/bash
# Versio: 1

ACCIO=$(basename $0 | awk -F. '{print $2}')
INSTANCIA=$(basename $0 | awk -F. '{print $1}')
DIRNAME=$(dirname $0)
USUARI=`whoami`

BASE_INSTALL=/opt/IBM

HTTPSERVERROOT=${BASE_INSTALL}/IHS90/HTTPServer
CONF=$HTTPSERVERROOT/conf/httpd.conf.$INSTANCIA
#CONF=conf/httpd.conf
#URL=$(grep -v ^# $HTTPSERVERROOT/$CONF | grep -i listen | grep :80 | awk '{print $2}')
URL="localhost:8001"
function searchIhs() {
        INSTANCIA=$1
        ps -fea | grep http | grep IHS90 | grep -q $INSTANCIA
        echo $?
}

function searchIhsPID() {
        INSTANCIA=$1
        PID=`ps -fea | egrep "http.*IHS90.*$INSTANCIA" | grep -v grep | awk '{print $2}'`
        echo $PID
}

function checkIhsStatus() {
        INSTANCIA=$1
        $DIRNAME/$INSTANCIA.status.sh 2>&1 >> /dev/null
        echo $?
}


function ihs_start() {
  if [ $(searchIhs $INSTANCIA) -eq 0 ]; then
        echo "Instancia $INSTANCIA ja est▒ arrencada. Aturi'la"
        exit 0
  fi

  echo "Arrancant $INSTANCIA"
  if [ $USUARI == was ]; then
        $HTTPSERVERROOT/bin/apachectl -f $CONF
  else
        su - was -c "$HTTPSERVERROOT/bin/apachectl -f $CONF"
  fi
  sleep 2

  if [ $( checkIhsStatus $INSTANCIA ) -eq 0 ] ; then
    echo "OK Instancia $INSTANCIA arrencada correctament"
    exit 0
  else
    echo "AL Instancia $INSTANCIA no s'ha arrencat correctament"
    exit 1
  fi

}

function ihs_stop() {
  if [ $( searchIhs $INSTANCIA ) -ne 0 ]; then
    echo "OK Instancia $INSTANCIA ja estava aturada"
    exit 0
  fi

  echo "Aturant $INSTANCIA"
  IHS_PIDS=`searchIhsPID $INSTANCIA`
  if [ ! -z "$IHS_PIDS" ]; then
          kill -9 $IHS_PIDS > /dev/null 2>&1
  fi
  sleep 2

  if [ $( searchIhs $INSTANCIA ) -ne 0 ]; then
    echo "OK Instancia $INSTANCIA aturada correctament"
    exit 0
  else
    echo "AL Instancia $INSTANCIA no s'ha aturat correctament"
    exit 1
  fi
}

function ihs_status() {
        CURL_OPTIONS="-A 'Monitoritzacio_WEB' --connect-timeout 3 --max-time 10"
        CURL_URL="http://${URL}/http/Advisors/Alive"
        CURL=$( which curl )
        $CURL $CURL_OPTIONS $CURL_URL 2>&1 |grep -q "HTTPServer OK"
        if [ $? -ne 0 ]; then
                 echo "CRITICAL Instancia $INSTANCIA en estat ALERTA"
                 exit 1
        fi
        echo "OK Instancia $INSTANCIA en estat correcte"
        exit 0
}

case "$ACCIO" in
start)
  ihs_start
  exit 0
  ;;

stop)
  ihs_stop
  exit 0
  ;;

status)
  ihs_status
  exit 0
  ;;

*)
  echo "Invalid parameter"
  exit 1
  ;;
esac