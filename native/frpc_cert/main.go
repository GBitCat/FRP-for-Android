package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static size_t frp_cert_strnlen(const char *value, size_t maximum) {
	return strnlen(value, maximum);
}
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"unsafe"
)

const abiVersion = 1

var requestMutex sync.Mutex

//export FrpCertAbiVersion
func FrpCertAbiVersion() C.uint32_t {
	return C.uint32_t(abiVersion)
}

//export FrpCertInvoke
func FrpCertInvoke(input *C.char) (result *C.char) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result = encodeCResponse(failure("INTERNAL_ERROR", "certificate engine failed"))
		}
	}()
	if input == nil {
		return encodeCResponse(failure("INVALID_REQUEST", "request is required"))
	}
	length := C.frp_cert_strnlen(input, C.size_t(maxRequestBytes+1))
	if length == 0 || length > C.size_t(maxRequestBytes) {
		return encodeCResponse(failure("INVALID_REQUEST", "request size is invalid"))
	}
	return encodeCResponse(handleJSONRequest(C.GoStringN(input, C.int(length))))
}

func handleJSONRequest(raw string) apiResponse {
	if len(raw) == 0 || len(raw) > maxRequestBytes {
		return failure("INVALID_REQUEST", "request size is invalid")
	}
	var request apiRequest
	if err := json.Unmarshal([]byte(raw), &request); err != nil {
		return failure("INVALID_REQUEST", "request is not valid JSON")
	}
	return dispatch(request)
}

//export FrpCertFree
func FrpCertFree(result unsafe.Pointer) {
	C.free(result)
}

func encodeCResponse(response apiResponse) *C.char {
	encoded, err := json.Marshal(response)
	if err != nil {
		return C.CString(`{"ok":false,"code":"INTERNAL_ERROR","message":"response encoding failed"}`)
	}
	return C.CString(string(encoded))
}

func main() {}

func dispatch(request apiRequest) apiResponse {
	requestMutex.Lock()
	defer requestMutex.Unlock()

	if request.APIVersion != abiVersion {
		return failure(
			"ABI_VERSION_MISMATCH",
			fmt.Sprintf("unsupported API version %d", request.APIVersion),
		)
	}
	root, err := prepareRoot(request.Root)
	if err != nil {
		return responseFromError(err)
	}
	request.Root = root

	var data any
	switch request.Operation {
	case "list_inventory":
		data, err = listInventory(request)
	case "create_ca":
		data, err = createAuthority(request)
	case "import_ca_recovery":
		data, err = importAuthorityRecovery(request)
	case "delete_ca":
		data, err = deleteAuthority(request)
	case "create_identity":
		data, err = createIdentity(request)
	case "delete_identity":
		data, err = deleteIdentity(request)
	case "sign_identity":
		data, err = signIdentity(request)
	case "install_identity":
		data, err = installIdentity(request)
	case "install_trusted_ca":
		data, err = installTrustedCA(request)
	case "inspect_csr":
		data, err = inspectCSR(request)
	case "validate_ca_bundle":
		data, err = validateCABundleRequest(request)
	case "sign_csr":
		data, err = signExternalCSR(request)
	case "generate_server_certificate":
		data, err = generateServerCertificate(request)
	case "delete_issued_certificate":
		data, err = deleteIssuedCertificate(request)
	default:
		return failure("UNKNOWN_OPERATION", "unsupported certificate operation")
	}
	if err != nil {
		return responseFromError(err)
	}
	return success(data)
}
