require 'redis'
require 'redis/connection/hiredis'

class RedisClient
  @@redis = (Thread.current[:isu_redis] ||= Redis.new(host: (ENV["REDIS_HOST"] || "127.0.0.1"), port: 6379))
  class << self
    def key_keyword_pattern
      "isu:keyword_pattern"
    end

    def key_keyword_count
      "isu:keyword_count"
    end

    def key_escaped_content(id)
      "isu:escaped_content:#{id}"
    end

    def keyword_pattern
      /#{@@redis.get(key_keyword_pattern)}+/o
    end

    def keyword_pattern=(pattern)
      @@redis.set(key_keyword_pattern.to_s, pattern)
    end

    def keyword_count
      @@redis.get(key_keyword_count).to_i
    end

    def keyword_count=(count)
      @@redis.set(key_keyword_count, count)
    end
  end
end
