package com.frp.app.utils

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.NetworkInterface

object NetworkUtils {
    
    data class IpAddresses(
        val ipv4: List<String> = emptyList(),
        val ipv6: List<String> = emptyList()
    )
    
    /**
     * 获取设备IP地址（优先使用 ConnectivityManager API，覆盖 WiFi + 蜂窝）
     */
    fun getDeviceIpAddresses(context: Context? = null): IpAddresses {
        val ipv4Set = linkedSetOf<String>()
        val ipv6Set = linkedSetOf<String>()
        
        // 方法1: ConnectivityManager（Android 推荐，覆盖所有活跃网络）
        if (context != null) {
            try {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                for (network in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(network) ?: continue
                    if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue
                    
                    val linkProps = cm.getLinkProperties(network) ?: continue
                    val ifaceName = linkProps.interfaceName ?: "unknown"
                    val isWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    val isCell = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                    val label = when {
                        isWifi -> "WiFi"
                        isCell -> "Cell"
                        else -> ifaceName
                    }
                    
                    for (linkAddr in linkProps.linkAddresses) {
                        val addr = linkAddr.address
                        val ip = addr.hostAddress?.substringBefore("%") ?: continue
                        
                        when (addr) {
                            is Inet4Address -> {
                                if (!addr.isLoopbackAddress && ip != "0.0.0.0") {
                                    ipv4Set.add("$label: $ip")
                                }
                            }
                            is Inet6Address -> {
                                if (!addr.isLoopbackAddress && !isLinkLocal(ip)) {
                                    ipv6Set.add("$label: $ip")
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        
        // 方法2: NetworkInterface 兜底（补充 ConnectivityManager 可能遗漏的接口）
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                if (networkInterface.isLoopback || !networkInterface.isUp) continue
                
                val ifaceName = networkInterface.displayName
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (address.isLoopbackAddress) continue
                    
                    val ip = address.hostAddress?.substringBefore("%") ?: continue
                    
                    when (address) {
                        is Inet4Address -> {
                            if (ip != "127.0.0.1" && ip != "0.0.0.0") {
                                ipv4Set.add("$ifaceName: $ip")
                            }
                        }
                        is Inet6Address -> {
                            if (!isLinkLocal(ip)) {
                                ipv6Set.add("$ifaceName: $ip")
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        
        return IpAddresses(ipv4Set.toList(), ipv6Set.toList())
    }
    
    // 判断是否是链路本地地址 (fe80::/10)
    private fun isLinkLocal(ip: String): Boolean {
        val lower = ip.lowercase()
        return lower.startsWith("fe80:") || lower.startsWith("fe8") || lower.startsWith("fe9") ||
               lower.startsWith("fea") || lower.startsWith("feb") || lower == "::1"
    }
    
    // 获取主要的IPv4地址
    fun getPrimaryIpv4(context: Context? = null): String? {
        // 优先从 ConnectivityManager 获取
        if (context != null) {
            try {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val activeNetwork = cm.activeNetwork
                if (activeNetwork != null) {
                    val linkProps = cm.getLinkProperties(activeNetwork)
                    if (linkProps != null) {
                        for (linkAddr in linkProps.linkAddresses) {
                            val addr = linkAddr.address
                            if (addr is Inet4Address && !addr.isLoopbackAddress) {
                                return addr.hostAddress
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        
        // 兜底: NetworkInterface
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                if (networkInterface.isLoopback || !networkInterface.isUp) continue
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (address is Inet4Address && !address.isLoopbackAddress) {
                        val ip = address.hostAddress
                        if (ip != null && ip != "127.0.0.1") return ip
                    }
                }
            }
        } catch (_: Exception) {}
        
        return null
    }
}
