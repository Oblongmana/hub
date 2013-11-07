require 'uri'
require 'yaml'
require 'forwardable'
require 'fileutils'

module Hub
  # Client for the GitLab v3 API.
  #
  # First time around, user gets prompted for username/password in the shell.
  # Then this information is exchanged for an OAuth token which is saved in a file.
  # 
  # As this class borrows heavily from github_api.rb, anything pulled in there
  #   from github/hub should also be looked over to see if it should be dropped
  #   into here
  #
  # Examples
  #
  #   @api_client ||= begin
  #     config_file = ENV['HUB_CONFIG'] || '~/.config/hub'
  #     file_store = GitLabAPI::FileStore.new File.expand_path(config_file)
  #     file_config = GitLabAPI::Configuration.new file_store
  #     GitLabAPI.new file_config
  #   end
  class GitLabAPI
    attr_reader :config

    # Public: Create a new API client instance
    #
    # Options:
    # - config: an object that implements:
    #   - username(host)
    #   - password(host, user)
    #   - auth_token(host, user)
    def initialize config
      @config = config
    end

    # Fake exception type for net/http exception handling.
    # Necessary because net/http may or may not be loaded at the time.
    module Exceptions
      def self.===(exception)
        exception.class.ancestors.map {|a| a.to_s }.include? 'Net::HTTPExceptions'
      end
    end

    def api_host host
      host = host.downcase
    end

    def test_get_projects gitlab_url
      res = get "https://%s/projects" % [api_host(gitlab_url)]
      res.data.each { |elem| puts "Project: #{elem['name']}" }
    end

    def test_useless_post gitlab_url
      res = post "https://%s/" % [api_host(gitlab_url)]
    end

    # # Public: Fetch data for a specific repo.
    # def repo_info project
    #   get "https://%s/repos/%s/%s" %
    #     [api_host(project.host), project.owner, project.name]
    # end

    # # Public: Fetch list of issues for a specific repo.
    # def repo_issues project, options = {}
    #   params = {}
    #   params[:state]        = options[:state]      if options[:state]
    #   get_with_params "https://%s/repos/%s/%s/issues" %
    #     [api_host(project.host), project.owner, project.name], params
    # end

    # # Public: Fetch list of labels for a specific repo.
    # def repo_labels project
    #   get "https://%s/repos/%s/%s/labels" %
    #     [api_host(project.host), project.owner, project.name]
    # end

    # # Public: Determine whether a specific repo exists.
    # def repo_exists? project
    #   repo_info(project).success?
    # end

    # # Public: Fork the specified repo.
    # def fork_repo project
    #   res = post "https://%s/repos/%s/%s/forks" %
    #     [api_host(project.host), project.owner, project.name]
    #   res.error! unless res.success?
    # end

    # # Public: Create a new project.
    # def create_repo project, options = {}
    #   is_org = project.owner.downcase != config.username(api_host(project.host)).downcase
    #   params = { :name => project.name, :private => !!options[:private] }
    #   params[:description] = options[:description] if options[:description]
    #   params[:homepage]    = options[:homepage]    if options[:homepage]

    #   if is_org
    #     res = post "https://%s/orgs/%s/repos" % [api_host(project.host), project.owner], params
    #   else
    #     res = post "https://%s/user/repos" % api_host(project.host), params
    #   end
    #   res.error! unless res.success?
    #   res.data
    # end

    # # Public: Create a new issue.
    # def create_issue project, options = {}
    #   params = {}
    #   params[:title]        = options[:title]      if options[:title]
    #   params[:state]        = options[:state]      if options[:state]
    #   params[:body]         = options[:body]       if options[:body]
    #   params[:assignee]     = options[:assignee]   if options[:assignee]
    #   params[:milestone]    = options[:milestone]  if options[:milestone]
    #   params[:labels]       = options[:labels]     if options[:labels]

    #   res = post "https://%s/repos/%s/%s/issues" % [api_host(project.host), project.owner, project.name], params
      
    #   res.error! unless res.success?
    #   res.data
    # end

    # # Public: Close an issue.
    # def close_issue project, issue_num
    #   params = {}
    #   params[:state] = "closed"
    #   res = post "https://%s/repos/%s/%s/issues/%s" % [api_host(project.host), project.owner, project.name, issue_num], params
      
    #   res.error! unless res.success?
    #   res.data
    # end


    # # Public: Fetch info about a pull request.
    # def pullrequest_info project, pull_id
    #   res = get "https://%s/repos/%s/%s/pulls/%d" %
    #     [api_host(project.host), project.owner, project.name, pull_id]
    #   res.error! unless res.success?
    #   res.data
    # end

    # # Returns parsed data from the new pull request.
    # def create_pullrequest options
    #   project = options.fetch(:project)
    #   params = {
    #     :base => options.fetch(:base),
    #     :head => options.fetch(:head)
    #   }

    #   if options[:issue]
    #     params[:issue] = options[:issue]
    #   else
    #     params[:title] = options[:title] if options[:title]
    #     params[:body]  = options[:body]  if options[:body]
    #   end

    #   res = post "https://%s/repos/%s/%s/pulls" %
    #     [api_host(project.host), project.owner, project.name], params

    #   res.error! unless res.success?
    #   res.data
    # end

    # def statuses project, sha
    #   res = get "https://%s/repos/%s/%s/statuses/%s" %
    #     [api_host(project.host), project.owner, project.name, sha]

    #   res.error! unless res.success?
    #   res.data
    # end


    # Methods for performing HTTP requests
    #
    # Requires access to a `config` object that implements:
    # - proxy_uri(with_ssl)
    # - username(host)
    # - update_username(host, old_username, new_username)
    # - password(host, user)
    module HttpMethods
      # Decorator for Net::HTTPResponse
      module ResponseMethods
        def status() code.to_i end
        def data?() content_type =~ /\bjson\b/ end
        def data() @data ||= JSON.parse(body) end
        def error_message?() data? and data['errors'] || data['message'] end
        def error_message() error_sentences || data['message'] end
        def success?() Net::HTTPSuccess === self end
        def error_sentences
          data['errors'].map do |err|
            case err['code']
            when 'custom'        then err['message']
            when 'missing_field'
              %(Missing field: "%s") % err['field']
            when 'invalid'
              %(Invalid value for "%s": "%s") % [ err['field'], err['value'] ]
            when 'unauthorized'
              %(Not allowed to change field "%s") % err['field']
            end
          end.compact if data['errors']
        end
      end

      def get url, &block
        perform_request url, :Get, &block
      end

      def get_with_params url, params = nil
        perform_request url, :Get do |req|
          if params
            require 'cgi'
            req.path.concat("?" + params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&')) unless params.nil?
          end
          yield req if block_given?
          req['Content-Length'] = byte_size req.body
        end
      end

      def post url, params = nil
        perform_request url, :Post do |req|
          if params
            req.body = JSON.dump params
            req['Content-Type'] = 'application/json;harset=utf-8'
          end
          yield req if block_given?
          req['Content-Length'] = byte_size req.body
        end
      end

      def byte_size str
        if    str.respond_to? :bytesize then str.bytesize
        elsif str.respond_to? :length   then str.length
        else  0
        end
      end

      def post_form url, params
        post(url) {|req| req.set_form_data params }
      end

      def perform_request url, type
        url = URI.parse url unless url.respond_to? :host

        require 'net/https'
        req = Net::HTTP.const_get(type).new request_uri(url)
        # TODO: better naming?
        http = configure_connection(req, url) do |host_url|
          create_connection host_url
        end

        req['User-Agent'] = "Hub #{Hub::VERSION}"
        apply_authentication(req, url) 
        yield req if block_given?

        begin
          res = http.start { http.request(req) }
          res.extend ResponseMethods
          return res
        rescue SocketError => err
          raise Context::FatalError, "error with #{type.to_s.upcase} #{url} (#{err.message})"
        end
      end

      def request_uri url
        str = url.request_uri
        str = '/api/v3' << str
        str
      end

      def configure_connection req, url
        if ENV['HUB_TEST_HOST']
          req['Host'] = url.host
          url = url.dup
          url.scheme = 'http'
          url.host, test_port = ENV['HUB_TEST_HOST'].split(':')
          url.port = test_port.to_i if test_port
        end
        yield url
      end

      def apply_authentication req, url
        # This is only hit for new session
        #   Add login/pass to req body for auth
        #   Add Content-Type json header
        user = url.user || config.username(url.host)
        pass = config.password(url.host, user)

        req['Content-Type'] = "application/json;charset=UTF-8"
        req.body = JSON.generate  "login" => user, "password" => pass 
      end

      def create_connection url
        use_ssl = 'https' == url.scheme

        proxy_args = []
        if proxy = config.proxy_uri(use_ssl)
          proxy_args << proxy.host << proxy.port
          if proxy.userinfo
            require 'cgi'
            # proxy user + password
            proxy_args.concat proxy.userinfo.split(':', 2).map {|a| CGI.unescape a }
          end
        end

        http = Net::HTTP.new(url.host, url.port, *proxy_args)

        if http.use_ssl = use_ssl
          # FIXME: enable SSL peer verification!
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end
        return http
      end
    end

    module Auth
      def apply_authentication req, url
        # hit for all requests, whether auth exists already or not
        # 
        # If hitting the authorization endpoint ("/session"), returns the url object (a URI)
        #   passed in, but with the necessary auth info added to the path
        #   
        # If being hit in an already authorized context, returns a hash
        #   from the name of the required auth header to the token value
        if (url.path =~ /\/session$/)
          super
        else
          # refresh = false
          user = url.user || config.username(url.host)
          token = config.auth_token(url.host, user) {
            # refresh = true
            obtain_auth_token url.host, user
          }
          # if refresh
          #   # get current user info user to persist correctly capitalized login name
          #   res = get "https://#{url.host}/user"
          #   res.error! unless res.success?
          #   config.update_username(url.host, user, res.data['login'])
          # end
          {"PRIVATE-TOKEN",token}
          # req['Authorization'] = "token #{token}"
        end
      end

      def obtain_auth_token host, user
        # create a new authorization
        # Note to self, this call out to authentications goes to the post method,
        #  which in turn goes via via Auth::apply_authentication
        #  through super to HttpMethods::apply_authentication, which does the basic_auth call
        res = post "https://#{host}/session"
        res.error! unless res.success?
        res.data['private_token']
      end
    end

    include HttpMethods
    include Auth

    # Filesystem store suitable for Configuration
    class FileStore
      extend Forwardable
      def_delegator :@data, :[], :get
      def_delegator :@data, :[]=, :set

      def initialize filename
        @filename = filename
        @data = Hash.new {|d, host| d[host] = [] }
        load if File.exist? filename
      end

      def fetch_user host
        unless entry = get(host).first
          user = yield
          # FIXME: more elegant handling of empty strings
          return nil if user.nil? or user.empty?
          entry = entry_for_user(host, user)
        end
        entry['user']
      end

      def fetch_value host, user, key
        entry = entry_for_user host, user
        entry[key.to_s] || begin
          value = yield
          if value and !value.empty?
            entry[key.to_s] = value
            save
            value
          else
            raise "no value"
          end
        end
      end

      def entry_for_user host, username
        entries = get(host)
        entries.find {|e| e['user'] == username } or
          (entries << {'user' => username}).last
      end

      def load
        existing_data = File.read(@filename)
        @data.update YAML.load(existing_data) unless existing_data.strip.empty?
      end

      def save
        FileUtils.mkdir_p File.dirname(@filename)
        File.open(@filename, 'w', 0600) {|f| f << YAML.dump(@data) }
      end
    end

    # Provides authentication info per GitLab host such as username, password,
    # and API/OAuth tokens.
    class Configuration
      def initialize store
        @data = store
        # passwords are cached in memory instead of persistent store
        @password_cache = {}
      end

      def normalize_host host
        host = host.downcase
      end

      def username host
        return ENV['GITLAB_USER'] unless ENV['GITLAB_USER'].to_s.empty?
        host = normalize_host host
        @data.fetch_user host do
          if block_given? then yield
          else prompt "#{host} username"
          end
        end
      end

      # def update_username host, old_username, new_username
      #   entry = @data.entry_for_user(normalize_host(host), old_username)
      #   entry['user'] = new_username
      #   @data.save
      # end

      def password host, user
        return ENV['GITLAB_PASSWORD'] unless ENV['GITLAB_PASSWORD'].to_s.empty?
        host = normalize_host host
        @password_cache["#{user}@#{host}"] ||= prompt_password host, user
      end

      def auth_token host, user, &block
        @data.fetch_value normalize_host(host), user, :auth_token, &block
      end

      def prompt what
        print "#{what}: "
        $stdin.gets.chomp
      rescue Interrupt
        abort
      end

      # special prompt that has hidden input
      def prompt_password host, user
        print "#{host} password for #{user} (never stored): "
        if $stdin.tty?
          password = askpass
          puts ''
          password
        else
          # in testing
          $stdin.gets.chomp
        end
      rescue Interrupt
        abort
      end

      NULL = defined?(File::NULL) ? File::NULL :
               File.exist?('/dev/null') ? '/dev/null' : 'NUL'

      def askpass
        tty_state = `stty -g 2>#{NULL}`
        system 'stty raw -echo -icanon isig' if $?.success?
        pass = ''
        while char = getbyte($stdin) and !(char == 13 or char == 10)
          if char == 127 or char == 8
            pass[-1,1] = '' unless pass.empty?
          else
            pass << char.chr
          end
        end
        pass
      ensure
        system "stty #{tty_state}" unless tty_state.empty?
      end

      def getbyte(io)
        if io.respond_to?(:getbyte)
          io.getbyte
        else
          # In Ruby <= 1.8.6, getc behaved the same
          io.getc
        end
      end

      def proxy_uri(with_ssl)
        env_name = "HTTP#{with_ssl ? 'S' : ''}_PROXY"
        if proxy = ENV[env_name] || ENV[env_name.downcase] and !proxy.empty?
          proxy = "http://#{proxy}" unless proxy.include? '://'
          URI.parse proxy
        end
      end
    end
  end
end