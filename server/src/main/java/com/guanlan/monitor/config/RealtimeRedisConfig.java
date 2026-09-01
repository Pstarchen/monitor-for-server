package com.guanlan.monitor.config;

import com.guanlan.monitor.realtime.RealtimeRedisSubscriber;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;
import org.springframework.data.redis.listener.adapter.MessageListenerAdapter;
import org.springframework.data.redis.serializer.StringRedisSerializer;

@Configuration
@ConditionalOnProperty(prefix = "app", name = "redis-enabled", havingValue = "true")
public class RealtimeRedisConfig {
    @Bean
    MessageListenerAdapter realtimeMessageListener(RealtimeRedisSubscriber subscriber) {
        MessageListenerAdapter adapter = new MessageListenerAdapter(subscriber, "receive");
        adapter.setSerializer(new StringRedisSerializer());
        return adapter;
    }

    @Bean
    RedisMessageListenerContainer realtimeRedisContainer(RedisConnectionFactory connectionFactory,
                                                         MessageListenerAdapter realtimeMessageListener,
                                                         RealtimeProperties properties) {
        RedisMessageListenerContainer container = new RedisMessageListenerContainer();
        container.setConnectionFactory(connectionFactory);
        container.addMessageListener(realtimeMessageListener, new ChannelTopic(properties.getRedisChannel()));
        return container;
    }
}
