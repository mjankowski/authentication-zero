require "rails/generators/active_record"

class AuthenticationGenerator < Rails::Generators::NamedBase
  include ActiveRecord::Generators::Migration

  class_option :api,       type: :boolean, desc: "Generates API authentication"
  class_option :pwned,     type: :boolean, desc: "Add pwned password validation"
  class_option :lockable,  type: :boolean, desc: "Add password reset locking"
  class_option :ratelimit, type: :boolean, desc: "Add request rate limiting"

  source_root File.expand_path("templates", __dir__)

  def add_gems
    uncomment_lines "Gemfile", /"bcrypt"/
    uncomment_lines "Gemfile", /"redis"/  if options.lockable?
    uncomment_lines "Gemfile", /"kredis"/ if options.lockable?
    gem "pwned", comment: "Use Pwned to check if a password has been found in any of the huge data breaches [https://github.com/philnash/pwned]" if options.pwned?
    gem "rack-ratelimit", group: :production, comment: "Use Rack::Ratelimit to rate limit requests [https://github.com/jeremy/rack-ratelimit]" if options.ratelimit?
  end

  def create_configuration_files
     copy_file "config/redis/shared.yml", "config/redis/shared.yml" if options.lockable?
  end

  def add_environment_configurations
     ratelimit_code = <<~CODE
      # Rate limit general requests by IP address in a rate of 1000 requests per hour
      config.middleware.use(Rack::Ratelimit, name: "General", rate: [1000, 1.hour], redis: Redis.new, logger: Rails.logger) { |env| ActionDispatch::Request.new(env).ip }
    CODE

    environment ratelimit_code, env: "production" if options.ratelimit?
  end

  def create_migrations
    migration_template "migrations/create_table_migration.rb", "#{db_migrate_path}/create_#{table_name}.rb"
    migration_template "migrations/create_sessions_migration.rb", "#{db_migrate_path}/create_sessions.rb"
  end

  def create_models
    template "models/model.rb", "app/models/#{file_name}.rb"
    template "models/session.rb", "app/models/session.rb"
    template "models/current.rb", "app/models/current.rb"
    template "models/locking.rb", "app/models/locking.rb" if options.lockable?
  end

  def create_fixture_file
    template "test_unit/fixtures.yml", "test/fixtures/#{fixture_file_name}.yml"
  end

  def add_application_controller_methods
    api_code = <<~CODE
      include ActionController::HttpAuthentication::Token::ControllerMethods

      before_action :authenticate

      def authenticate
        if session = authenticate_with_http_token { |token, _| Session.find_signed(token) }
          Current.session = session
        else
          request_http_token_authentication
        end
      end

      def require_sudo
        if Current.session.sudo_at < 30.minutes.ago
          render json: { error: "Enter your password to continue" }, status: :forbidden
        end
      end
    CODE

    html_code = <<~CODE
      before_action :authenticate

      def authenticate
        if session = Session.find_by_id(cookies.signed[:session_token])
          Current.session = session
        else
          redirect_to sign_in_path
        end
      end

      def require_sudo
        if Current.session.sudo_at < 30.minutes.ago
          redirect_to new_sudo_path(proceed_to_url: request.url)
        end
      end
    CODE

    inject_code = options.api? ? api_code : html_code
    inject_into_class "app/controllers/application_controller.rb", "ApplicationController", optimize_indentation(inject_code, 2), verbose: false
  end

  def create_controllers
    directory "controllers/#{format_folder}", "app/controllers"
  end

  def create_views
    if options.api?
      directory "erb/identity_mailer", "app/views/identity_mailer"
      directory "erb/session_mailer", "app/views/session_mailer"
    else
      directory "erb", "app/views"
    end
  end

  def create_mailers
    directory "mailers", "app/mailers"
  end

  def add_routes
    route "resource :sudo, only: [:new, :create]"
    route "resource :registration, only: :destroy"
    route "resource :password_reset, only: [:new, :edit, :create, :update]"
    route "resource :password, only: [:edit, :update]"
    route "resource :email_verification, only: [:edit, :create]"
    route "resource :email, only: [:edit, :update]"
    route "resources :sessions, only: [:index, :show, :destroy]"
    route "post 'sign_up', to: 'registrations#create'"
    route "get 'sign_up', to: 'registrations#new'" unless options.api?
    route "post 'sign_in', to: 'sessions#create'"
    route "get 'sign_in', to: 'sessions#new'" unless options.api?
  end

  def create_test_files
    directory "test_unit/controllers/#{format_folder}", "test/controllers"
    directory "test_unit/system", "test/system" unless options.api?
  end

  private
    def format_folder
      options.api? ? "api" : "html"
    end
end
