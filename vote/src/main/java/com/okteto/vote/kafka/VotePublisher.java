package com.okteto.vote.kafka;

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * Responsabilidad única: publicar un voto protegiendo el sistema con
 * Circuit Breaker como capa externa.
 *
 * Patrón Circuit Breaker — se aplica aquí como capa externa.
 * Delega el envío real a KafkaSender (que tiene @Retry).
 * El Circuit Breaker ve el resultado final de todos los reintentos:
 *   - Si KafkaSender agota los reintentos y lanza excepción → CB registra fallo.
 *   - Si el 50% de las últimas 10 llamadas fallan → circuito se ABRE.
 *   - Con el circuito abierto → publishFallback() se llama inmediatamente,
 *     sin llegar a KafkaSender, preservando los threads del servidor.
 *   - Después de 30 segundos → pasa a half-open para probar recuperación.
 */
@Service
public class VotePublisher {

    private static final Logger logger = LoggerFactory.getLogger(VotePublisher.class);
    private static final String INSTANCE = "kafkaPublish";

    @Autowired
    private KafkaSender kafkaSender;

    @CircuitBreaker(name = INSTANCE, fallbackMethod = "publishFallback")
    public boolean publish(String topic, String key, String value) {
        kafkaSender.send(topic, key, value);
        return true;
    }

    /**
     * Fallback: se invoca cuando el circuito está abierto o cuando
     * KafkaSender agotó todos sus reintentos.
     * Registra el evento y devuelve false para que el controlador
     * pueda informar al usuario en lugar de responder con error 500.
     */
    public boolean publishFallback(String topic, String key, String value, Exception ex) {
        logger.error("Circuit breaker activo — voto '{}' (voter='{}') no entregado a Kafka. Causa: {}",
                value, key, ex.getMessage());
        return false;
    }
}
