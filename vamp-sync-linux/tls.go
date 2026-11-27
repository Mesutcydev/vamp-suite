package main

/*
#cgo pkg-config: openssl
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <string.h>

typedef struct {
	char identity[32];
	unsigned char key[32];
} vamp_psk;

static unsigned int vamp_get_psk(SSL *ssl, const char *identity, unsigned char *key, unsigned int size) {
	vamp_psk *psk = SSL_get_app_data(ssl);
	if (!identity || strcmp(identity, psk->identity) || size < 32) return 0;
	memcpy(key, psk->key, 32);
	return 32;
}

static SSL_CTX *vamp_ctx(const unsigned char *cert, size_t cert_size, const unsigned char *key, size_t key_size) {
	SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
	if (!ctx) return NULL;
	X509 *x509 = d2i_X509(NULL, &cert, cert_size);
	EVP_PKEY *pkey = d2i_AutoPrivateKey(NULL, &key, key_size);
	int ok = x509 && pkey && SSL_CTX_use_certificate(ctx, x509) &&
		SSL_CTX_use_PrivateKey(ctx, pkey) &&
		SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) &&
		SSL_CTX_set_cipher_list(ctx, "RSA-PSK-AES256-GCM-SHA384:PSK-AES256-GCM-SHA384");
	EVP_PKEY_free(pkey);
	X509_free(x509);
	if (!ok) { SSL_CTX_free(ctx); return NULL; }

	SSL_CTX_set_psk_server_callback(ctx, vamp_get_psk);
	SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
	SSL_CTX_set_options(ctx, SSL_OP_NO_RENEGOTIATION | SSL_OP_NO_TICKET);
	SSL_CTX_set_num_tickets(ctx, 0);
	return ctx;
}

static SSL *vamp_tls(SSL_CTX *ctx, int fd, const char *name, const void *key) {
	SSL *ssl = SSL_new(ctx);
	if (!ssl) return NULL;
	vamp_psk *psk = OPENSSL_zalloc(sizeof(*psk));
	if (!psk || !SSL_set_fd(ssl, fd)) {
		OPENSSL_free(psk);
		SSL_free(ssl);
		return NULL;
	}
	strncpy(psk->identity, name, sizeof(psk->identity) - 1);
	memcpy(psk->key, key, 32);
	SSL_set_app_data(ssl, psk);
	return ssl;
}

static int vamp_psk_authenticated(SSL *ssl) {
	// TLS 1.3 may fall back to certificate authentication when peers omit a
	// PSK. Only an external PSK resumption can pass (tickets are disabled).
	return SSL_version(ssl) < TLS1_3_VERSION || SSL_session_reused(ssl);
}

static void vamp_free(SSL *ssl) {
	OPENSSL_clear_free(SSL_get_app_data(ssl), sizeof(vamp_psk));
	SSL_free(ssl);
}

// Call SSL_get_error on the same OS thread as the SSL operation.
static int vamp_tls_op(SSL *ssl, int op, void *buf, int size, int *status) {
	ERR_clear_error();
	int n;
	if (op == 0) n = SSL_accept(ssl);
	else if (op == 1) n = SSL_read(ssl, buf, size);
	else n = SSL_write(ssl, buf, size);
	*status = n > 0 ? 0 : SSL_get_error(ssl, n);
	return n;
}
*/
import "C"

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"io"
	"math/big"
	"net"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

var errTLS = errors.New("TLS-PSK handshake or I/O failed")

type tlsContext struct{ ctx *C.SSL_CTX }

func newTLSContext() (*tlsContext, error) {
	// RSA-PSK (0x00AD) requires a transport certificate. Vamp peers authenticate
	// the host's long-lived P-256 signing identity separately at the wire layer.
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Vamp Sync"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(1, 0, 0),
		KeyUsage: x509.KeyUsageKeyEncipherment,
	}
	cert, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	der := x509.MarshalPKCS1PrivateKey(key)
	ctx := C.vamp_ctx((*C.uchar)(unsafe.Pointer(&cert[0])), C.size_t(len(cert)),
		(*C.uchar)(unsafe.Pointer(&der[0])), C.size_t(len(der)))
	if ctx == nil {
		return nil, errTLS
	}
	return &tlsContext{ctx}, nil
}

func (t *tlsContext) close() { C.SSL_CTX_free(t.ctx) }

type tlsSocket struct {
	raw  syscall.RawConn
	conn *net.TCPConn
	mu   sync.Mutex
	ssl  *C.SSL
}

func (t *tlsContext) accept(conn *net.TCPConn, name string, key []byte) (*tlsSocket, error) {
	if len(key) != 32 {
		return nil, errTLS
	}
	raw, err := conn.SyscallConn()
	if err != nil {
		return nil, err
	}
	nameC := C.CString(name)
	defer C.free(unsafe.Pointer(nameC))
	s := &tlsSocket{raw: raw, conn: conn}
	err = raw.Control(func(fd uintptr) {
		s.ssl = C.vamp_tls(t.ctx, C.int(fd), nameC, unsafe.Pointer(&key[0]))
	})
	if err != nil {
		return nil, err
	}
	if s.ssl == nil {
		return nil, errTLS
	}

	// A server handshake can alternate between needing to read and write.
	var status C.int
	var n C.int
	wait := raw.Read
	for {
		err = wait(func(uintptr) bool {
			n = C.vamp_tls_op(s.ssl, 0, nil, 0, &status)
			if n > 0 {
				return true
			}
			if status == C.SSL_ERROR_WANT_READ {
				return false
			}
			return true
		})
		if err != nil || n > 0 || status != C.SSL_ERROR_WANT_WRITE {
			break
		}
		err = raw.Write(func(uintptr) bool {
			n = C.vamp_tls_op(s.ssl, 0, nil, 0, &status)
			return status != C.SSL_ERROR_WANT_WRITE
		})
		if err != nil || n > 0 || status != C.SSL_ERROR_WANT_READ {
			break
		}
	}
	if err != nil || n <= 0 || C.vamp_psk_authenticated(s.ssl) == 0 {
		s.free()
		return nil, errTLS
	}
	return s, nil
}

func (s *tlsSocket) io(op C.int, p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	var n, status C.int
	wait, retry := s.raw.Read, C.int(C.SSL_ERROR_WANT_READ)
	if op == 2 {
		wait, retry = s.raw.Write, C.int(C.SSL_ERROR_WANT_WRITE)
	}
	if err := wait(func(uintptr) bool {
		s.mu.Lock()
		n = C.vamp_tls_op(s.ssl, op, unsafe.Pointer(&p[0]), C.int(len(p)), &status)
		s.mu.Unlock()
		return status != retry
	}); err != nil {
		return 0, err
	}
	if n > 0 {
		return int(n), nil
	}
	if status == C.SSL_ERROR_ZERO_RETURN {
		return 0, io.EOF
	}
	return 0, errTLS
}

func (s *tlsSocket) Read(b []byte) (int, error) { return s.io(1, b) }
func (s *tlsSocket) Write(b []byte) (int, error) {
	for offset := 0; offset < len(b); {
		n, err := s.io(2, b[offset:])
		offset += n
		if err != nil {
			return offset, err
		}
	}
	return len(b), nil
}

func (s *tlsSocket) free() { C.vamp_free(s.ssl) }
