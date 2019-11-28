#!/bin/bash

declare -a PORTS
HEADERS=""
NAMESERVER=""
ip=""
hostname=""

Usage(){
	echo "Usage: $0 [ OPTIONS ]"
	echo "-h, --help	print this message"
	echo "-P, --port port 	proxy traffic to this port, this option can repeat"
	echo "			eg: -P 80 -P 443 -P 8080"
	echo "			default:80"
	echo "-H, --header	headers add by transparent proxy,this option can repeat"
	echo "			eg: -H header:value"
	echo "-N, --nameserver 	nameserver used by transparent proxy, this option can repeat"
	echo "			eg: -N 114.114.114.114 -N 8.8.8.8"
	echo "			default nameserver use the value in /etc/resolve.conf"
	echo ""
	echo "--Set-Forwarded-For	transparent proxy add X-Forwarded-For Header"
	echo "				default: use env PODIP"
	echo "--Set-Client-Hostname 	transparent proxy add X-Client-Hostname Header"
	echo "				default: use hostname"
}

Nameserver(){
	local os=`cat /etc/os-release | grep "VERSION_CODENAME" | awk -F = '{print$2}'`
	if [ $os == "bionic" ];then
		cat /etc/systemd/resolv.conf | grep "DNS" | awk -F = '{print$2}'
	else
		cat /etc/resolv.conf | grep nameserver | awk '{print$2}'
	fi
}

Nicip(){
	local nic=`ip route | grep default | awk '{print$5}'`
	ip addr show $nic | grep inet | awk '{print$2}'| grep -Eo '([0-9]*\.){3}[0-9]*'
}

NginxStart(){
	mkdir -p /run/nginx
	egrep "^nginx" /etc/passwd >& /dev/null
	if [ $? -ne 0 ];then
		useradd -s /bin/false nginx
	fi
	nginx
}

SetIptables(){
	iptables -t nat -N LOCAL_PROXY
	iptables -t nat -A LOCAL_PROXY -m owner --uid-owner nginx -j RETURN
	
	if [[ ${#PORTS[@]} == 0 ]];then
		port=80
		iptables -t nat -A LOCAL_PROXY -p tcp -m tcp --dport $port -j REDIRECT --to-ports $port
	else
		for i in ${!PORTS[@]};do
			port=$i
			iptables -t nat -A LOCAL_PROXY -p tcp -m tcp --dport $port -j REDIRECT --to-ports $port
		done
	fi
	iptables -t nat -A OUTPUT -p tcp -j LOCAL_PROXY
}

HttpConfig(){
port=$1
cat >> /etc/nginx/conf.d/default.conf <<EOF
server {
    listen	127.0.0.1:$port;
    server_name localhost;

    location / {
	#access_log /var/log/nginx/access.$port.log tranproxy
	resolver $NAMESERVER
	proxy_pass http://\$host:\$port\$request_url;
	$HEADERS 
	}
}
EOF
}

HttpsConfig(){
port=$1
cat >> /etc/nginx/conf.d/ssl.conf <<EOF
stream {
    resolver $NAMESERVER;
    server {
        listen 127.0.0.1:$port;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_pass \$host:$port\$request_url;
	$HEADERS
    }
}
EOF
}

while :; do
	case $1 in 
		-h|-\?|--help)
			Usage
			exit
			;;
		-P|--port)
			if [[ $2 == "" || ${2:0:1} == "-" ]];then
				echo 'ERROR: "-P|--port" requires a non-empty option argument.' 2>&1
				exit 1
			fi
			PORTS["$2"]=$2
			shift
			;;
		-H|--header)
			if [[ $2 == "" || ${2:0:1} == "-" ]];then
				echo 'Error:"-H, --header" requires a non-empty option argument.' 2>&1 
				exit 1
			fi
			read name value <<< "${2//:/}";
			HEADERS="$HEADERS\n\tproxy_set_header $name \"$value\";"
			shift
			;;
		-N|--nameserver)
			if [[ $2 == "" || ${2:0:1} == "-" ]];then
				echo 'ERROR: "-N/--nameserver" requires a non-empty option argument.' 2>&1
				exit 1
			fi
			NAMESERVER="$NAMESERVER $2"
			shift
			;;
		--Set-Forwarded-For)
			if [[ $2 == "" || ${2:0:1} == "-" ]];then
				echo 'ERROR: "--Set-Forwarded-For" requires a non-empty option argument, support "default".' 2>&1
				exit 1
			fi
			if [[ $2 == "default" ]];then
				if [[ "$PODIP" ]];then
					IP=$PODIP
					HEADERS="$HEADERS\n\tproxy_set_header X-Forwarded-For \"$IP\";"
				else
					IP=`NicIP`
					HEADERS="$HEADERS\n\tproxy_set_header X-Forwarded-For \"$IP\";"
				fi
			else
				IP=$2
				HEADERS="$HEADERS\n\tproxy_set_header X-Forwarded-For \"$IP\";"
			fi
			shift
			;;
		--Set-Client-Hostname)
			if [[ $2 == "" || ${2:0:1} == "-" ]];then
				echo 'ERROR: "--Set-Client-Hostname" requires a non-empty option argument, support "default".' 2>&1
				exit 1
			fi
			if [[ $2 == "default" ]];then
				host=`hostname`
				HEADERS="$HEADERS\n\tproxy_set_header X-Client-Hostname \"$host\";"
			else
				host=$2
				HEADERS="$HEADERS\n\tproxy_set_header X-Client-Hostname \"$host\";"
			fi
			shift
			;;
		-|--)
			shift
			break
			;;
		*)
			break
			;;
	esac
	shift
done

echo "################### Start ##################"
echo `date`
echo "############# Setting: Proxy Port ##########"
echo ${PORTS[@]}

if [[ $NAMESERVER == "" ]];then
	NAMESERVER=`Nameserver`
fi
echo "############# Setting: Proxy Nameserver ##########"
echo $NAMESERVER

HEADERS=`echo -e $HEADERS`
echo "############# Setting: Set Headers ##########"
echo $HEADERS

echo "">/etc/nginx/conf.d/default.conf
if [[ ${#PORTS[@]} -ne 0 ]];then
	echo "use default port: 80"
	HttpConfig 80
else
	for i in ${!PORTS[@]};do
		if [[ $i -ne 443 ]];then
			touch /etc/nginx/conf.d/ssl.conf
			echo "" >/etc/nginx/conf.d/ssl.conf
			HttpsConfig $i
		else
			HttpConfig $i
		fi
	done
fi
echo "############# Nginx Final Config ##########"
[ -f "/etc/nginx/conf.d/default.conf" ] && echo "/etc/nginx/conf.d/default.conf is" && cat /etc/nginx/conf.d/default.conf
[ -f "/etc/nginx/conf.d/ssl.conf" ] && echo "/etc/nginx/conf.d/ssl.conf is" && cat /etc/nginx/conf.d/ssl.conf

echo "############# NginxStart ##########"
NginxStart
echo "############# SetIptables ##########"
SetIptables

if [ "$*" ];then
	echo "############# ExecuteCmd ##########"
	echo "execute cmds: $*"
	$*
fi

while true;do
	sleep 10
	echo "running@`date`"
done
