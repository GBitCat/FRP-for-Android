package com.frp.app

import com.frp.app.data.ExportData
import com.frp.app.data.FrpConfig
import com.frp.app.data.ServerConfig
import com.google.gson.Gson
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigImportExportTest {

    @Test
    fun `export includes server config`() {
        val gson = Gson()
        val server = ServerConfig(
            name = "Home Server",
            serverAddr = "1.2.3.4",
            serverPort = 7000,
            token = "secret",
            serverId = "ABCD1234",
            protocol = "tcp",
            tcpMux = true
        )
        val config = FrpConfig(name = "xtcp_visitor", localPort = 0, protocol = "xtcp", bindPort = 39522)
        val json = gson.toJson(ExportData(configs = listOf(config), server = server))

        assertTrue("should contain server block", json.contains("\"server\""))
        assertTrue("should contain serverId", json.contains("ABCD1234"))
        assertTrue("should contain serverAddr", json.contains("1.2.3.4"))
        assertTrue("should contain configs", json.contains("\"configs\""))
        assertTrue("should contain config name", json.contains("xtcp_visitor"))
        println(json)
    }

    @Test
    fun `import parses export data`() {
        val gson = Gson()
        val json = """{"version":1,"server":{"id":1,"name":"Home","serverAddr":"5.6.7.8","serverPort":7000,"serverId":"ZZZZ9999"},"configs":[{"id":0,"name":"cfg1","localPort":22}]}"""
        val data = gson.fromJson(json, ExportData::class.java)
        assertTrue(data.server?.serverAddr == "5.6.7.8")
        assertTrue(data.server?.serverId == "ZZZZ9999")
        assertTrue(data.configs.size == 1)
        assertTrue(data.configs[0].name == "cfg1")
    }
}
