# configures nginx and adds unicorn and other servers as a service running this application

# Example:
#
#   bash script/install/service.bash
#
# adds a service $APP_NAME (from install.cfg, eg. nztrain) that starts the application
# which can be controlled via
#
#   sudo service nztrain start

cd `dirname $0`/../..

if [ -z $CONFIG_LOADED ]; then
  source script/install.cfg
fi

NGINX_INSTALL_DIR="/usr/local/nginx"

# nginx includes this app configuration
bash $RAILS_ROOT/script/template.bash < $RAILS_ROOT/script/install/nginx.app.conf | cat > $NGINX_INSTALL_DIR/conf/$APP_NAME.app.conf

(
  RAILS_ENV=production
  cd config/procfiles/$RAILS_ENV
  foreman export upstart /etc/init
)

