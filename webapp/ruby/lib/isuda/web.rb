require 'digest/sha1'
require 'json'
require 'net/http'
require 'uri'

require 'erubis'
require 'mysql2'
require 'mysql2-cs-bind'
require 'rack/utils'
require 'sinatra/base'
require 'tilt/erubis'

require '/home/isucon/webapp/ruby/lib/redis_client.rb'

module Isuda
  class Web < ::Sinatra::Base
    enable :protection
    enable :sessions

    set :erb, escape_html: true
    set :public_folder, File.expand_path('../../../../public', __FILE__)
    set :db_user, 'isucon'
    set :db_password, 'isucon'
    set :session_secret, 'tonymoris'
    set :isupam_origin, ENV['ISUPAM_ORIGIN'] || 'http://localhost:5050'
    set :isutar_origin, ENV['ISUTAR_ORIGIN'] || 'http://localhost:5001'

    configure :development do
      require 'sinatra/reloader'

      register Sinatra::Reloader
    end

    set(:set_name) do |value|
      condition {
        user_id = session[:user_id]
        if user_id
          user = db.xquery(%| select name from user where id = ? |, user_id).first
          @user_id = user_id
          @user_name = user[:name]
          halt(403) unless @user_name
        end
      }
    end

    set(:authenticate) do |value|
      condition {
        halt(403) unless @user_id
      }
    end

    helpers do
      def db
        Thread.current[:db] ||=
          begin
            mysql = Mysql2::Client.new(
              username: settings.db_user,
              password: settings.db_password,
              database: 'isuda',
              encoding: 'utf8mb4',
              init_command: %|SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY'|,
            )
            mysql.query_options.update(symbolize_keys: true)
            mysql
          end
      end

      def register(name, pw)
        chars = [*'A'..'~']
        salt = 1.upto(20).map { chars.sample }.join('')
        salted_password = encode_with_salt(password: pw, salt: salt)
        db.xquery(%|
          INSERT INTO user (name, salt, password, created_at)
          VALUES (?, ?, ?, NOW())
        |, name, salt, salted_password)
        db.last_id
      end

      def encode_with_salt(password: , salt: )
        Digest::SHA1.hexdigest(salt + password)
      end

      def is_spam_content(content)
        isupam_uri = URI(settings.isupam_origin)
        res = Net::HTTP.post_form(isupam_uri, 'content' => content)
        validation = JSON.parse(res.body)
        validation['valid']
        ! validation['valid']
      end

      def htmlify(content, id)
        return RedisClient.get_escaped_content(id) if RedisClient.exists_escaped_content?(id)

        unless RedisClient.get_keyword_count == db.xquery(%| select COUNT(1) AS count from entry |).first[:count]
          update_keyword_pattern
        end

        kw2hash = {}
        hashed_content = content.gsub(RedisClient.get_keyword_pattern) {|m|
          "isuda_#{Digest::SHA1.hexdigest(m.to_s)}".tap do |hash|
            kw2hash[m.to_s] = hash
          end
        }
        escaped_content = Rack::Utils.escape_html(hashed_content)
        kw2hash.each do |(keyword, hash)|
          keyword_url = url("/keyword/#{Rack::Utils.escape_path(keyword)}")
          anchor = '<a href="%s">%s</a>' % [keyword_url, Rack::Utils.escape_html(keyword)]
          escaped_content.gsub!(hash, anchor)
        end

        escaped_content.gsub(/\n/, "<br />\n").tap do |content|
          RedisClient.set_escaped_content(content, id) unless RedisClient.exists_escaped_content?(id)
        end
      end

      def update_keyword_pattern
        keywords = db.xquery(%| select keyword from entry order by character_length(keyword) desc |)
        RedisClient.set_keyword_pattern(/#{keywords.map {|k| Regexp.escape(k[:keyword]) }.join('|')}/)
        RedisClient.set_keyword_count(keywords.to_a.size)
      end

      def uri_escape(str)
        Rack::Utils.escape_path(str)
      end

      def redirect_found(path)
        redirect(path, 302)
      end

      def invalidate_escaped_content(keyword)
        should_invalidate_entry_ids = db.xquery(%|
          SELECT id
          FROM entry
          WHERE description LIKE "%?%"
        |, keyword).to_a.map {|v| v[:id] }

        return if should_invalidate_entry_ids.empty?
        RedisClient.invalidate_escaped_content(*should_invalidate_entry_ids)
      end
    end

    get '/initialize' do
      db.xquery(%| DELETE FROM entry WHERE id > 7101 |)
      db.xquery(%| TRUNCATE star|)

      update_keyword_pattern

      content_type :json
      JSON.generate(result: 'ok')
    end

    get '/', set_name: true do
      per_page = 10
      page = (params[:page] || 1).to_i

      entries = db.xquery(%|
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT #{per_page}
        OFFSET #{per_page * (page - 1)}
      |)

      stars = db.xquery(%|
        select
          keyword, GROUP_CONCAT(user_name) AS user_names
        from star
        where
          keyword IN (?)
        group by keyword
      |, [entries.map { |entry| entry[:keyword] }.uniq]
      ).to_a.map {|val| [val[:keyword], val[:user_names]]}.to_h

      entries.each do |entry|
        entry[:html] = htmlify(entry[:description], entry[:id])
        entry[:stars] = (stars[entry[:keyword]] || "").split(',').map {|v| {user_name: v}}
      end

      total_entries = db.xquery(%| SELECT count(1) AS total_entries FROM entry |).first[:total_entries].to_i

      last_page = (total_entries.to_f / per_page.to_f).ceil
      from = [1, page - 5].max
      to = [last_page, page + 5].min
      pages = [*from..to]

      locals = {
        entries: entries,
        page: page,
        pages: pages,
        last_page: last_page,
      }
      erb :index, locals: locals
    end

    get '/robots.txt' do
      halt(404)
    end

    get '/register', set_name: true do
      erb :register
    end

    post '/register' do
      name = params[:name] || ''
      pw   = params[:password] || ''
      halt(400) if (name == '') || (pw == '')

      user_id = register(name, pw)
      session[:user_id] = user_id

      redirect_found '/'
    end

    get '/login', set_name: true do
      locals = {
        action: 'login',
      }
      erb :authenticate, locals: locals
    end

    post '/login' do
      name = params[:name]
      user = db.xquery(%| select * from user where name = ? |, name).first
      halt(403) unless user
      halt(403) unless user[:password] == encode_with_salt(password: params[:password], salt: user[:salt])

      session[:user_id] = user[:id]

      redirect_found '/'
    end

    get '/logout' do
      session[:user_id] = nil
      redirect_found '/'
    end

    post '/keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] || ''
      halt(400) if keyword == ''
      description = params[:description]
      halt(400) if is_spam_content(description) || is_spam_content(keyword)

      bound = [@user_id, keyword, description] * 2
      db.xquery(%|
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
      |, *bound)

      invalidate_escaped_content(keyword)

      redirect_found '/'
    end

    get '/keyword/:keyword', set_name: true do
      keyword = params[:keyword] or halt(400)

      entry = db.xquery(%| select * from entry where keyword = ? |, keyword).first or halt(404)
      entry[:stars] = db.xquery(%| select * from star where keyword = ? |, entry[:keyword]).to_a
      entry[:html] = htmlify(entry[:description], entry[:id])

      locals = {
        entry: entry,
      }
      erb :keyword, locals: locals
    end

    post '/keyword/:keyword', set_name: true, authenticate: true do
      keyword = params[:keyword] or halt(400)
      is_delete = params[:delete] or halt(400)

      unless db.xquery(%| SELECT keyword FROM entry WHERE keyword = ? |, keyword).first
        halt(404)
      end

      invalidate_escaped_content(keyword)

      db.xquery(%| DELETE FROM entry WHERE keyword = ? |, keyword)

      redirect_found '/'
    end

    get '/stars' do
      keyword = params[:keyword] || ''
      stars = db.xquery(%| select * from star where keyword = ? |, keyword).to_a

      content_type :json
      JSON.generate(stars: stars)
    end

    post '/stars' do
      keyword = params[:keyword]
      db.xquery(%| select keyword from entry where keyword = ? |, keyword).first or halt(404)

      user_name = params[:user]
      db.xquery(%|
        INSERT INTO star (keyword, user_name, created_at)
        VALUES (?, ?, NOW())
      |, keyword, user_name)

      content_type :json
      JSON.generate(result: 'ok')
    end
  end
end
