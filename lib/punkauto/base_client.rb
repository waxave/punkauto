# frozen_string_literal: true

require "faraday"
require "faraday/cookie_jar"
require "faraday/follow_redirects"
require "http/cookie_jar"
require "json"

module Punkauto
  # Base client with common HTTP functionality.
  class BaseClient
    API_ENDPOINT = "https://www.rockauto.com/catalog/catalogapi.php"
    CATALOG_BASE = "https://www.rockauto.com/en/catalog"

    attr_reader :use_mobile_profile, :session
    attr_accessor :is_authenticated, :user_email,
                  :last_navigation_context, :current_year_context

    def initialize(use_mobile_profile: true)
      @use_mobile_profile = use_mobile_profile
      @cookie_jar = HTTP::CookieJar.new
      seed_initial_cookies
      @session = build_session

      @is_authenticated = false
      @user_email = nil
      @last_navigation_context = nil
      @current_year_context = nil
    end

    def close
      @session.close if @session.respond_to?(:close)
    end

    # Hash of current session cookies (name => value).
    def cookies
      @cookie_jar.cookies.each_with_object({}) do |cookie, hash|
        hash[cookie.name] = cookie.value
      end
    end

    def login(email, password, keep_signed_in: false)
      form_data = {
        "loginaction" => "login",
        "accountemail" => email,
        "captchacode" => "",
        "passworddecoy" => "",
        "password" => password,
        "passwordconfirmdecoy" => "",
        "passwordconfirm" => "",
        "keepsignin" => keep_signed_in ? "true" : "false",
        "async" => "1",
        "accountlogin_php" => "1"
      }

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
        "Referer" => "https://www.rockauto.com/",
        "X-Requested-With" => "XMLHttpRequest",
        "Accept" => "text/plain, */*; q=0.01",
        "Accept-Language" => "en-US,en;q=0.9",
        "Accept-Encoding" => "gzip, deflate, br",
        "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Sec-Ch-Ua" => '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
        "Sec-Ch-Ua-Mobile" => "?0",
        "Sec-Ch-Ua-Platform" => '"Windows"',
        "Sec-Fetch-Dest" => "empty",
        "Sec-Fetch-Mode" => "cors",
        "Sec-Fetch-Site" => "same-origin",
        "Cache-Control" => "no-cache",
        "Pragma" => "no-cache"
      }

      response = @session.post(API_ENDPOINT, form_data, headers)

      begin
        response_json = JSON.parse(response.body)

        if response_json["accountcaptchaerror"] == 1
          @is_authenticated = false
          @user_email = nil
          raise Error, "CAPTCHA required: RockAuto is requiring a security code for login. This typically happens when automated requests are detected. Try logging in manually through a browser first."
        end

        if response_json["error"]
          @is_authenticated = false
          @user_email = nil
          raise Error, "Login error: #{response_json['error']}"
        end

        if response_json["message"] == "Log In Successful" &&
           response_json["email"] == email &&
           response_json["act"] == "login"
          @is_authenticated = true
          @user_email = email
          return true
        else
          @is_authenticated = false
          @user_email = nil
          return false
        end
      rescue JSON::ParserError, KeyError
        response_text = response.body.to_s.downcase
        if response_text.include?("log in successful")
          @is_authenticated = true
          @user_email = email
          return true
        else
          @is_authenticated = false
          @user_email = nil
          return false
        end
      end
    rescue StandardError => e
      @is_authenticated = false
      @user_email = nil
      raise Error, "Login failed: #{e.message}"
    end

    def logout
      form_data = {
        "loginaction" => "logout",
        "async" => "1",
        "accountlogin_php" => "1"
      }

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => "https://www.rockauto.com/",
        "X-Requested-With" => "XMLHttpRequest"
      }

      @session.post(API_ENDPOINT, form_data, headers)

      @is_authenticated = false
      @user_email = nil

      auth_cookie_keys = %w[session login auth user]
      @cookie_jar.cookies.each do |cookie|
        if auth_cookie_keys.any? { |key| cookie.name.downcase.include?(key) }
          @cookie_jar.delete(cookie)
        end
      end

      true
    rescue StandardError => e
      raise Error, "Logout failed: #{e.message}"
    end

    def authentication_status
      {
        "is_authenticated" => @is_authenticated,
        "user_email" => @user_email,
        "has_session_cookies" => !cookies.empty?
      }
    end

    def make_api_request(func, payload)
      data = {
        "func" => func,
        "payload" => JSON.generate(payload),
        "api_json_request" => "1",
        "sctchecked" => "1",
        "scbeenloaded" => "false",
        "curCartGroupID" => ""
      }

      api_headers = {
        "Accept" => "text/plain, */*; q=0.01",
        "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With" => "XMLHttpRequest",
        "Referer" => "https://www.rockauto.com/",
        "Sec-Fetch-Dest" => "empty",
        "Sec-Fetch-Mode" => "cors",
        "Sec-Fetch-Site" => "same-origin"
      }

      response = @session.post(API_ENDPOINT, data, api_headers)
      JSON.parse(response.body)
    rescue StandardError => e
      raise Error, "API request failed: #{e.message}"
    end

    def simulate_navigation_context(make: nil, year: nil)
      if make
        catalog_href = "https://www.rockauto.com/en/catalog/#{make.downcase}"
        @cookie_jar.add(http_cookie("lastcathref", catalog_href))
        @last_navigation_context = catalog_href
      end

      if year
        @cookie_jar.add(http_cookie("year_#{year}", "true"))
        @current_year_context = year
      end

      if make
        navnode_payload = {
          "jsn" => {
            "groupindex" => "46",
            "tab" => "catalog",
            "make" => make.upcase,
            "nodetype" => "make",
            "jsdata" => {
              "markets" => [
                { "c" => "US", "y" => "Y", "i" => "Y" },
                { "c" => "CA", "y" => "Y", "i" => "Y" },
                { "c" => "MX", "y" => "Y", "i" => "Y" }
              ],
              "mktlist" => "US,CA,MX",
              "showForMarkets" => { "US" => true, "CA" => true, "MX" => true },
              "importanceByMarket" => { "US" => "Y", "CA" => "Y", "MX" => "Y" },
              "Show" => 1
            },
            "label" => make.upcase,
            "href" => catalog_href,
            "labelset" => true,
            "jump_to_after_expand" => true,
            "dont_change_url" => true,
            "has_more_auto_open_steps" => true,
            "loaded" => false,
            "expand_after_load" => true,
            "fetching" => true
          },
          "max_group_index" => 363
        }

        nav_headers = {
          "Accept" => "text/plain, */*; q=0.01",
          "Accept-Language" => "en-US,en;q=0.9",
          "Cache-Control" => "no-cache",
          "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
          "Origin" => "https://www.rockauto.com",
          "Pragma" => "no-cache",
          "Referer" => catalog_href,
          "Sec-Fetch-Dest" => "empty",
          "Sec-Fetch-Mode" => "cors",
          "Sec-Fetch-Site" => "same-origin",
          "X-Requested-With" => "XMLHttpRequest"
        }

        data = {
          "func" => "navnode_fetch",
          "payload" => JSON.generate(navnode_payload),
          "api_json_request" => "1",
          "sctchecked" => "1",
          "scbeenloaded" => "false",
          "curCartGroupID" => ""
        }

        @session.post(API_ENDPOINT, data, nav_headers)
      end
    rescue StandardError
      # Don't fail the main request if navigation simulation fails.
      nil
    end

    private

    def build_session
      Faraday.new(headers: default_headers, request: { timeout: 30, open_timeout: 30 }) do |conn|
        conn.use :cookie_jar, jar: @cookie_jar
        conn.request :url_encoded
        conn.response :follow_redirects
        conn.response :raise_error
        conn.adapter Faraday.default_adapter
      end
    end

    def default_headers
      if use_mobile_profile
        {
          "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1",
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language" => "en-US,en;q=0.9",
          "Accept-Encoding" => "gzip, deflate, br",
          "Sec-Fetch-Dest" => "document",
          "Sec-Fetch-Mode" => "navigate",
          "Sec-Fetch-Site" => "none",
          "Sec-Fetch-User" => "?1",
          "Upgrade-Insecure-Requests" => "1",
          "Cache-Control" => "max-age=0"
        }
      else
        {
          "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
          "Accept-Language" => "en-US,en;q=0.9",
          "Accept-Encoding" => "gzip, deflate, br, zstd",
          "Sec-Ch-Ua" => '"Chromium";v="139", "Not;A=Brand";v="99"',
          "Sec-Ch-Ua-Mobile" => "?0",
          "Sec-Ch-Ua-Platform" => '"Linux"',
          "Sec-Fetch-Dest" => "document",
          "Sec-Fetch-Mode" => "navigate",
          "Sec-Fetch-Site" => "none",
          "Sec-Fetch-User" => "?1",
          "Upgrade-Insecure-Requests" => "1",
          "Cache-Control" => "max-age=0"
        }
      end
    end

    def seed_initial_cookies
      initial = {
        "idlist" => "0",
        "mkt_CA" => "false",
        "mkt_MX" => "false",
        "year_2005" => "true",
        "ck" => "1",
        "mkt_US" => "true"
      }
      initial.each { |name, value| @cookie_jar.add(http_cookie(name, value)) }
    end

    def http_cookie(name, value)
      HTTP::Cookie.new(
        name: name,
        value: value,
        domain: "www.rockauto.com",
        path: "/",
        for_domain: true
      )
    end
  end
end
