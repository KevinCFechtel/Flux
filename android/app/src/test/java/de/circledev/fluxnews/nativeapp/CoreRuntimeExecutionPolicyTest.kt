package de.circledev.fluxnews.nativeapp

import org.junit.Assert.assertEquals
import org.junit.Test

class CoreRuntimeExecutionPolicyTest {
    @Test
    fun executionPolicyIsSmallAndBounded() {
        assertEquals(2, CoreRuntimeExecutionPolicy.LOCAL_WORKERS)
        assertEquals(1, CoreRuntimeExecutionPolicy.REMOTE_WORKERS)
        assertEquals(64, CoreRuntimeExecutionPolicy.EVENT_BUFFER_CAPACITY)
    }
}
