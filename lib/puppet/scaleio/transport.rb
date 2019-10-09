require "net/https"
require "rest-client"
require "cgi"
require "json"

require "puppet"

module Puppet
  module ScaleIO
    class Transport
      attr_accessor :host, :port, :user, :password, :scaleio_cookie

      def initialize(opts)
        self.user = opts[:username]
        self.host = opts[:server]
        self.password = opts[:password]
        self.port = opts[:port] || 443
      end

      def cgi_escape(value)
        CGI.escape(value)
      end

      def get_scaleio_cookie
        return @scaleio_cookie unless @scaleio_cookie.nil?

        response = ""
        url = "https://%s:%s@%s:%s/api/login" % [cgi_escape(self.user),
                                                 cgi_escape(self.password),
                                                 self.host,
                                                 self.port]

        begin

          response = RestClient::Request.execute(
              :url => url,
              :method => :get,
              :verify_ssl => false ,
              :payload => '{}',
              :headers => {:content_type => :json,
                           :accept => :json })

        rescue => ex
          raise("failed to get the cookie: %s" % ex.to_s) if ex.response.nil? || ex.response.body.nil?
          response_body = JSON.parse(ex.response.body)

          unless response_body["message"].include?("no MDM IP is set")
            raise("Failed to get cookie: %s: %s: %s" % [ex.class, ex.to_s, response_body])
          end
          response = "NO MDM"
          Puppet.err "Failed to get cookie from ScaleIO Gateway with error %s" % [response_body]
        end
        @scaleio_cookie = response.strip.tr('""', '')
      end

      def get_url(end_point)
        return "https://%s:%s@%s:%s/%s" % [self.user, self.get_scaleio_cookie, self.host, self.port, end_point]
      end

      def post_request(url, payload, method)
        response = RestClient::Request.execute(:url => url,
                                               :method => method.to_sym,
                                               :verify_ssl => false,
                                               :payload => payload,
                                               :headers => headers
        )
        JSON.parse(response)
      end

      def headers
        {
            :content_type => :json,
            :accept => :json,
            'Cookie' => self.scaleio_cookie || get_scaleio_cookie
        }
      end

      def vxos_im_login_url
        "https://%s/j_spring_security_check" % [self.host]
      end

      def vxos_im_jsession_id
        @__jsession_id ||= begin
          RestClient::Request.execute(
            :url => vxos_im_login_url,
            :method => :post,
            :verify_ssl => false,
            :max_redirect => 0,
            :payload => "j_username=%s&j_password=%s&submit=Login" % ["admin", cgi_escape(self.password)])
        end
      rescue RestClient::ExceptionWithResponse => e
        @__jsession_id = e.response.cookies["JSESSIONID"]
      rescue
        require 'pry'; binding.pry
        retry_count ||= 0
        if retry_count >= 5
          raise("Failed to retrieve JSESSION ID for IM REST APIs after 5 attempts")
        else
          retry_count += 1
          Puppet.debug("Failed to retrieve JSESSION ID. Retry attempt %s" % [retry_count])
          sleep(10)
          retry
        end
      end

      def get_im_url(end_point)
        "https://%s%s" % [self.host, end_point]
      end

      def im_headers(content_type="json")
        if content_type == "form"
          header = {
            :content_type => "multipart/form-data",
            :cookie => "JSESSIONID=%s" % [vxos_im_jsession_id]
          }
        else
          header = {
            :content_type => "application/json",
            :accept => :json,
            :cookie => "JSESSIONID=%s" % [vxos_im_jsession_id]
          }
        end

        header
      end

      def post_im_request(end_point, payload, method, content_type="json")
        plain_content_type = ["application/octet-stream", "text/html"]
        response = RestClient::Request.execute(:url => end_point,
                                               :method => method.to_sym,
                                               :verify_ssl => false,
                                               :payload => payload,
                                               :headers => im_headers(content_type),
                                               :cookies => {"JSESSIONID" => vxos_im_jsession_id})
        if !response.empty? &&
          response.respond_to?(:headers) &&
          plain_content_type.include?(response.headers[:content_type])
        else
          JSON.parse(response) unless response.empty?
        end
      end
    end
  end
end
