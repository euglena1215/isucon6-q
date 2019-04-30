require 'redis'
require 'redis/connection/hiredis'

class RedisClient
  @@redis = (Thread.current[:isu_redis] ||= Redis.new(host: (ENV["REDIS_HOST"] || "127.0.0.1"), port: 6379))
  class << self
    def get_keyword_pattern
      /#{@@redis.get(key_keyword_pattern)}/
    end

    def set_keyword_pattern(pattern)
      @@redis.set(key_keyword_pattern.to_s, pattern)
    end

    def get_keyword_count
      @@redis.get(key_keyword_count).to_i
    end

    def set_keyword_count(count)
      @@redis.set(key_keyword_count, count)
    end

    def get_escaped_content(id)
      @@redis.get(key_escaped_content(id))
    end

    def set_escaped_content(content, id)
      @@redis.set(key_escaped_content(id), content)
    end

    def exists_escaped_content?(id)
      @@redis.exists(key_escaped_content(id)) == "1"
    end

    def invalidate_escaped_content(ids)
      @@redis.del(key_escaped_content(*ids))
    end

    private

    def key_keyword_pattern
      "isu:keyword_pattern"
    end

    def key_keyword_count
      "isu:keyword_count"
    end

    def key_escaped_content(id)
      "isu:escaped_content:#{id}"
    end
  end
end
