package com.okteto.vote.kafka;

import io.github.resilience4j.retry.annotation.Retry;
import org.apache.kafka.common.KafkaException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;

import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Responsabilidad única: enviar un mensaje a Kafka de forma síncrona.
 *
 * Patrón Retry — se aplica aquí como capa interna.
 * En cada llamada a send() que falle con KafkaException se reintenta
 * hasta MAX_ATTEMPTS veces antes de propagar la excepción al caller.
 * SerializationException está excluida: un mensaje malformado no se
 * resuelve reintentando.
 *
 * Está separado de VotePublisher para que el Circuit Breaker (capa
 * externa) vea el resultado final de todos los reintentos, no el de
 * cada intento individual.
 */
@Service
public class KafkaSender {

    private static final Logger logger = LoggerFactory.getLogger(KafkaSender.class);
    private static final String INSTANCE = "kafkaPublish";

    @Autowired
    private KafkaTemplate<String, String> kafkaTemplate;

    @Retry(name = INSTANCE)
    public void send(String topic, String key, String value) {
        try {
            kafkaTemplate.send(topic, key, value).get(2, TimeUnit.SECONDS);
            logger.debug("Mensaje '{}' entregado a Kafka (topic={})", value, topic);
        } catch (TimeoutException e) {
            throw new KafkaException("Timeout al publicar voto en Kafka", e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new KafkaException("Hilo interrumpido al publicar voto en Kafka", e);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException re) {
                throw re;
            }
            throw new KafkaException("Error al publicar voto: " + cause.getMessage(), cause);
        }
    }
}
