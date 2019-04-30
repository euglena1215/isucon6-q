require 'redis'
require 'redis/connection/hiredis'

class RedisClient
  class << self
    @redis = (Thread.current[:isu_redis] ||= Redis.new(host: (ENV["REDIS_HOST"] || "127.0.0.1"), port: 6379))
  end
end
