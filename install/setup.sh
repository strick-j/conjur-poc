#Conjur POC Install - Master install and base policies
#Please verify the commands ran before running this script in your environment

# Global Variables
reset=`tput sgr0`
me=`basename "${0%.sh}"`

# Generic output functions
print_head(){
  local white=`tput setaf 7`
  echo ""
  echo "==========================================================================="
  echo "${white}$1${reset}"
  echo "==========================================================================="
  echo ""
}
print_info(){
  local white=`tput setaf 7`
  echo "${white}INFO: $1${reset}"
  echo "INFO: $1" >> ${me}.log
}
print_success(){
  local green=`tput setaf 2`
  echo "${green}SUCCESS: $1${reset}"
  echo "SUCCESS: $1" >> ${me}.log
}
print_error(){
  local red=`tput setaf 1`
  echo "${red}ERROR: $1${reset}"
  echo "ERROR: $1" >> ${me}.log
}
print_warning(){
  local yellow=`tput setaf 3`
  echo "${yellow}WARNING: $1${reset}"
  echo "WARNING: $1" >> ${me}.log
}

checkOS(){
print_head "Verifying OS"
touch ${me}.log
echo "Log file generated on $(date)" >> ${me}.log
case "$(cat /etc/*-release | grep -w ID_LIKE)" in
  'ID_LIKE="rhel fedora"' )
    print_success "OS is $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')"
    install_yum $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')
    ;;
  'ID_LIKE="fedora"' )
    print_success "OS is $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')"
    install_yum $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')
    ;;
  'ID_LIKE=debian' )
    print_success "OS is $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')"
    install_apt $(cat /etc/*-release | grep -w PRETTY_NAME | sed 's/PRETTY_NAME=//')
    ;;
esac
}

install_yum(){
print_head "Installing required packages for $1"

#Update OS
print_info "Installing dependencies via yum"
print_info "Installing updates - this may take some time"
sudo yum update -y >> ${me}.log

#install Docker CE
print_info "Installing pre-requisite packages - this may take some time"
pkgarray=(yum-utils device-mapper-persistent-data lvm2)
for pkg in ${pkgarray[@]}
do
  pkg="$pkg"
  sudo yum list $pkg > /dev/null
  if [[ $? -eq 0 ]]; then 
    print_info "Installing $pkg"
    sudo yum -y install $pkg >> ${me}.log
    sudo yum list installed $pkg > /dev/null
    if [[ $? -eq 0 ]]; then
      print_success "$pkg installed"
    else
      print_error "$pkg could not be installed. Exiting..."
      exit 1
    fi
  else
    print_error "Required package - $pkg - not found. Exiting..."
    exit 1
  fi
done
print_success "Required packages installed."

print_info "Adding Docker Repo"
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >> ${me}.log 

print_info "Installing Docker"
sudo yum -y install docker-ce >> ${me}.log
sudo yum list installed docker-ce > /dev/null
if [[ $? -eq 0 ]]; then
  print_success "docker-ce installed"
else
  print_error "docker-ce could not be installed. Exiting..."
  exit 1
fi

#config docker to start automatically and start the service
print_info "Enabling Docker"
sudo systemctl start docker
sudo systemctl enable /usr/lib/systemd/system/docker.service >> ${me}.log 2>&1

#initiate conjur install
install_conjur
}

install_apt(){
print_head "Installing required packages for $1"
print_info "Installing dependencies via apt"
#update OS
sudo apt-get upgrade -y

#Install packages to allow apt to use a repository over HTTPS:
sudo apt-get install apt-transport-https ca-certificates curl software-properties-common -y

#Add Docker’s official GPG key:
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

#Set up stable docker repository
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

#Install latest version of docker-ce
sudo apt-get install docker-ce -y

#initiate conjur install
install_conjur
}

install_conjur(){
print_head "Installing Conjur"
print_info "Gathering installation information"
#Gather Company Name
local done=0
while : ; do
  read -p 'Please enter your company name: ' compvar
  print_info "You entered $compvar, is this correct (Yes or No)?"
  select yn in "Yes" "No"; do
    case $yn in
      Yes ) local done=1; sed -i "s+company_name=.*+company_name=$compvar+g" config.ini; break;;
      No ) echo ""; break;;
    esac
  done
  if [[ "$done" -ne 0 ]]; then
    break
  fi
done

#Gather Hostname
local done=0
while : ; do
  read -p 'Please enter fully qualified domain name or hostname: ' hostvar
  print_info "You entered $hostvar, is this correct (Yes or No)?"
  select yn in "Yes" "No"; do
    case $yn in
      Yes ) local done=1; sed -i "s+master_name=.*+master_name=$hostvar+g" config.ini; break;;
      No ) echo ""; break;;
    esac
  done
  if [[ "$done" -ne 0 ]]; then
    break
  fi
done

#Load ini variables
local master_name=$(cat $PWD/config.ini | awk '/master_name=/' | sed 's/master_name=//')
local company_name=$(cat $PWD/config.ini | awk '/company_name=/' | sed 's/company_name=//')
local admin_password=$(cat $PWD/config.ini | awk '/admin_password=/' | sed 's/admin_password=//')

#Updating cli-retrieve script based on config.ini
print_info "Updating scripts based on user input"
sed -i "s+acme+$company_name+g" $PWD/policy/cli-retrieve-password.sh
sed -i "s+conjur-master+$master_name+g" $PWD/policy/cli-retrieve-password.sh

#Load the Conjur container. Place conjur-appliance-version.tar.gz in the same folder as this script
print_info "Searching for Conjur appliance image"
tarname=$(find conjur-app*)
if [ -f $PWD/$tarname ]; then
  print_info "Conjur appliance image found - $tarname - loading now"
else
  print_error "No Conjur appliance image found. Exiting..."
  exit 1
fi
conjur_image=$(sudo docker load -i $tarname)
conjur_image=$(echo $conjur_image | sed 's/Loaded image: //')

#create docker network
print_info "Creating Docker network for Conjur"
sudo docker network create conjur >> ${me}.log

#start docker master container named "conjur-master"
print_info "Creating Conjur container. Container name will be $master_name"
sudo docker container run -d --name $master_name --network conjur --restart=always --security-opt=seccomp:unconfined -p 443:443 -p 5432:5432 -p 1999:1999 $conjur_image

#creates company namespace and configures conjur for secrets storage
print_info "Configuring Conjur based on user inputs - this may take a while"
sudo docker exec $master_name evoke configure master --hostname $master_name --admin-password $admin_password $company_name
#if [[ "$(tail -n 1 ${me}.log)" == "Configuration successful. Conjur master up and running." ]]; then
#  print_success "$(tail -n 1 ${me}.log)"
#else
#  print_error "Conjur install failed. Review ${me}.log for more info. Exiting..."
#  exit 1
#fi

if [[ "$(docker ps -q -f name=$mastername)" ]]; then
  print_success "Conjur container is running"
else
  print_error "Conjur is not running. Review ${me}.log for more info. Exiting..."
  exit 1
fi


#configure conjur policy and load variables
configure_conjur
}

configure_conjur(){
#create CLI container
print_head "Configuring Conjur via Conjur CLI"
local master_name=$(cat $PWD/config.ini | awk '/master_name=/' | sed 's/master_name=//')
local company_name=$(cat $PWD/config.ini | awk '/company_name=/' | sed 's/company_name=//')
local admin_password=$(cat $PWD/config.ini | awk '/admin_password=/' | sed 's/admin_password=//')
print_info "Creating Conjur CLI Container - this may take a while"
sudo docker container run -d --name conjur-cli --network conjur --restart=always --entrypoint '' cyberark/conjur-cli:5 sleep infinity
if [[ "$(docker ps -q -f name=conjur-cli)" ]]; then
  print_success "Conjur CLI container is running"
else
  print_error "Conjur CLI is not running. Review ${me}.log for more info. Exiting..."
  exit 1
fi

#copy policy into container 
print_info "Copying Conjur policy into Conjur CLI Container"
sudo docker cp policy/ conjur-cli:/

#Init conjur session from CLI container
print_info "Initializing Conjur"
sudo docker exec -i conjur-cli conjur init --account $company_name --url https://$master_name <<< yes

#Login to conjur and load policy
print_head "Loading Conjur policy"
sudo docker exec conjur-cli conjur authn login -u admin -p $admin_password
sudo docker exec conjur-cli conjur policy load --replace root /policy/root.yml
sudo docker exec conjur-cli conjur policy load apps /policy/apps.yml >> ${me}.log
sudo docker exec conjur-cli conjur policy load apps/secrets /policy/secrets.yml

#set values for passwords in secrets policy
print_head "Creating Conjur secrets"
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/ansible_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/electric_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/openshift_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/docker_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/aws_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/azure_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/cd-variables/kubernetes_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/ci-variables/puppet_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/ci-variables/chef_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
sudo docker exec conjur-cli conjur variable values add apps/secrets/ci-variables/jenkins_secret $(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32)
}

checkOS
