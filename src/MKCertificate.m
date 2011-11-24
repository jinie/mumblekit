/* Copyright (C) 2009-2010 Mikkel Krautz <mikkel@krautz.dk>
   Copyright (c) 2005-2010 Thorvald Natvig, <thorvald@natvig.com>

   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
   - Neither the name of the Mumble Developers nor the names of its
     contributors may be used to endorse or promote products derived from this
     software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
   CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import <MumbleKit/MKCertificate.h>

#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pkcs12.h>
#include <time.h>
#include <xlocale.h>

#import <CommonCrypto/CommonDigest.h>


NSString *MKCertificateItemCommonName   = @"CN";
NSString *MKCertificateItemCountry      = @"C";
NSString *MKCertificateItemOrganization = @"O";
NSString *MKCertificateItemSerialNumber = @"serialNumber";


static int add_ext(X509 * crt, int nid, char *value) {
    X509_EXTENSION *ex;
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, crt, crt, NULL, NULL, 0);
    ex = X509V3_EXT_conf_nid(NULL, &ctx, nid, value);
    if (!ex)
        return 0;
    
    X509_add_ext(crt, ex, -1);
    X509_EXTENSION_free(ex);
    return 1;
}

@interface MKCertificate () {
    NSData          *_derCert;
    NSData          *_derPrivKey;
    
    NSDictionary    *_subjectDict;
    NSDictionary    *_issuerDict;
    
    NSDate          *_notAfterDate;
    NSDate          *_notBeforeDate;
    
    NSMutableArray  *_emailAddresses;
    NSMutableArray  *_dnsEntries;
}

- (void) setCertificate:(NSData *)cert;
- (NSData *) certificate;

- (void) setPrivateKey:(NSData *)pkey;
- (NSData *) privateKey;

- (void) extractCertInfo;

@end

@implementation MKCertificate

// fixme(mkrautz): Move this function somewhere else if other pieces of the library
//                 needs OpenSSL.
+ (void) initialize {
    // Make sure OpenSSL is initialized...
    OpenSSL_add_all_algorithms();

    // On Unix systems OpenSSL makes sure its PRNG is seeded with
    // random data from /dev/random or /dev/urandom. It would probably
    // be a good idea to seed it more than this. Fixme?
}

- (void) dealloc {
    [_derCert release];
    [_derPrivKey release];
    [super dealloc];
}

- (void) setCertificate:(NSData *)cert {
    _derCert = [cert retain];
}

- (NSData *) certificate {
    return _derCert;
}

- (void) setPrivateKey:(NSData *)pkey {
    _derPrivKey = [pkey retain];
}

- (NSData *) privateKey {
    return _derPrivKey;
}

// Returns an autoreleased MKCertificate object constructed by the given DER-encoded
// certificate and private key.
+ (MKCertificate *) certificateWithCertificate:(NSData *)cert privateKey:(NSData *)privkey {
    MKCertificate *ourCert = [[MKCertificate alloc] init];
    [ourCert setCertificate:cert];
    [ourCert setPrivateKey:privkey];
    [ourCert extractCertInfo];
    return [ourCert autorelease];
}

// Generate a self-signed certificate with the given name and email address as
// a MKCertificate object.
+ (MKCertificate *) selfSignedCertificateWithName:(NSString *)aName email:(NSString *)anEmail {
    return [MKCertificate selfSignedCertificateWithName:aName email:anEmail rsaKeyPair:nil];
}

// Generate a self-signed certificate with the given name and email address as
// a MKCertificate object.  Can also take an MKRSAKeyPair which it will use instead
// of generating its own.
+ (MKCertificate *) selfSignedCertificateWithName:(NSString *)aName email:(NSString *)anEmail rsaKeyPair:(MKRSAKeyPair *)keyPair {
    CRYPTO_mem_ctrl(CRYPTO_MEM_CHECK_ON);

    X509 *x509 = X509_new();

    EVP_PKEY *pubkey = NULL, *privkey = NULL;
    
    if (keyPair == nil) {
        keyPair = [MKRSAKeyPair generateKeyPairOfSize:2048 withDelegate:nil];
    }
    
    const unsigned char *buf = [[keyPair publicKey] bytes];
    NSUInteger len = [[keyPair publicKey] length];
    pubkey = d2i_PublicKey(EVP_PKEY_RSA, NULL, &buf, len);

    buf = [[keyPair privateKey] bytes];
    len = [[keyPair privateKey] length];
    privkey = d2i_AutoPrivateKey(NULL, &buf, len);
    
    X509_set_version(x509, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509),1);
    X509_gmtime_adj(X509_get_notBefore(x509),0);
    X509_gmtime_adj(X509_get_notAfter(x509),60*60*24*365*20);
    X509_set_pubkey(x509, pubkey);

    X509_NAME *name = X509_get_subject_name(x509);

    NSString *certName = aName;
    if (certName == nil) {
        certName = @"Mumble User";
    }

    NSString *certEmail = nil;
    if (anEmail == nil)
        anEmail = @"";
    certEmail = [NSString stringWithFormat:@"email:%@", anEmail];

    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8, (unsigned char *)[certName UTF8String], -1, -1, 0);
    X509_set_issuer_name(x509, name);
    add_ext(x509, NID_basic_constraints, "critical,CA:FALSE");
    add_ext(x509, NID_ext_key_usage, "clientAuth");
    add_ext(x509, NID_subject_key_identifier, "hash");
    add_ext(x509, NID_netscape_comment, "Generated by Mumble");
    add_ext(x509, NID_subject_alt_name, (char *)[certEmail UTF8String]);

    X509_sign(x509, privkey, EVP_sha1());

    MKCertificate *cert = [[MKCertificate alloc] init];
    {
        NSMutableData *data = [[NSMutableData alloc] initWithLength:i2d_X509(x509, NULL)];
        unsigned char *ptr = [data mutableBytes];
        i2d_X509(x509, &ptr);
        [cert setCertificate:data];
        [data release];
    }
    
    [cert setPrivateKey:[keyPair privateKey]];

    X509_free(x509);

    return [cert autorelease];
}

// Import a PKCS12-encoded certificate, public key and private key using the given password.
+ (MKCertificate *) certificateWithPKCS12:(NSData *)pkcs12 password:(NSString *)password {
    MKCertificate *retcert = nil;
    X509 *x509 = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *pkcs = NULL;
    BIO *mem = NULL;
    STACK_OF(X509) *certs = NULL;
    int ret = 0;

    mem = BIO_new_mem_buf((void *)[pkcs12 bytes], [pkcs12 length]);
    (void) BIO_set_close(mem, BIO_NOCLOSE);
    pkcs = d2i_PKCS12_bio(mem, NULL);
    if (pkcs) {
        ret = PKCS12_parse(pkcs, NULL, &pkey, &x509, &certs);
        if (pkcs && !pkey && !x509 && [password length] > 0) {
            if (certs) {
                if (ret)
                    sk_X509_free(certs);
                certs = NULL;
            }
            ret = PKCS12_parse(pkcs, [password UTF8String], &pkey, &x509, &certs);
        }
        if (pkey && x509 && X509_check_private_key(x509, pkey)) {
            unsigned char *dptr;

            NSMutableData *key = [NSMutableData dataWithLength:i2d_PrivateKey(pkey, NULL)];
            dptr = [key mutableBytes];
            i2d_PrivateKey(pkey, &dptr);

            NSMutableData *crt = [NSMutableData dataWithLength:i2d_X509(x509, NULL)];
            dptr = [crt mutableBytes];
            i2d_X509(x509, &dptr);

            retcert = [MKCertificate certificateWithCertificate:crt privateKey:key];
        }
    }

    if (ret) {
        if (pkey)
            EVP_PKEY_free(pkey);
        if (x509)
            X509_free(x509);
        if (certs)
            sk_X509_free(certs);
    }
    if (pkcs)
        PKCS12_free(pkcs);
    if (mem)
        BIO_free(mem);

    return retcert;
}

// Export a MKCertificate object as a PKCS12-encoded NSData blob. This is useful for
// APIs that only accept PKCS12 encoded data for import, like some the iOS keychain
// APIs.
- (NSData *) exportPKCS12WithPassword:(NSString *)password {
    X509 *x509 = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *pkcs = NULL;
    BIO *mem = NULL;
    STACK_OF(X509) *certs = sk_X509_new_null();
    const unsigned char *p;
    long size;
    char *data = NULL;
    NSData *retData = nil;

    if (!_derCert || !_derPrivKey) {
        return nil;
    }

    p = [_derPrivKey bytes];
    pkey = d2i_AutoPrivateKey(NULL, &p, [_derPrivKey length]);

    if (pkey) {
        p = [_derCert bytes];
        x509 = d2i_X509(NULL, &p, [_derCert length]);

        if (x509 && X509_check_private_key(x509, pkey)) {
            X509_keyid_set1(x509, NULL, 0);
            X509_alias_set1(x509, NULL, 0);

            /* fixme(mkrautz): Currently we only support exporting our own self-signed certs,
               which obviously do not have any intermediate certificates. If we need to add
               this in the future, do this: */
#if 0
            for (/* each certificate*/) {
                unsigned char *p = [data bytes];
                X509 *c = d2i_X509(NULL, &p, [data len])
                if (c)
                    sk_X509_push(certs, c);
            }
#endif

            pkcs = PKCS12_create(password ? (char *) [password UTF8String] : NULL, "Mumble Identity", pkey, x509, certs, 0, 0, 0, 0, 0);
            if (pkcs) {
                mem = BIO_new(BIO_s_mem());
                i2d_PKCS12_bio(mem, pkcs);
                int _flush __attribute__((unused)) = BIO_flush(mem);
                size = BIO_get_mem_data(mem, &data);
                retData = [[NSData alloc] initWithBytes:data length:size];
            }
        }
    }

    if (pkey)
        EVP_PKEY_free(pkey);
    if (x509)
        X509_free(x509);
    if (pkcs)
        PKCS12_free(pkcs);
    if (mem)
        BIO_free(mem);
    if (certs)
        sk_X509_free(certs);

    return [retData autorelease];
}

- (BOOL) hasCertificate {
    return _derCert != nil;
}

- (BOOL) hasPrivateKey {
    return _derPrivKey != nil;
}

// Parse a one-line UTF8 representation of subject or issuer info
// from a certificate. Returns a dictionary with the keys and values
// as-is.
- (NSDictionary *) copyDictForOneLineUTF8Repr:(NSData *)data {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"str = %@", str);
    NSArray *components = [str componentsSeparatedByString:@", "];
    NSLog(@"components = %@", components);
    for (NSString *component in components) {
        NSArray *pairs = [component componentsSeparatedByString:@" = "];
        if ([pairs count] != 2) {
            [dict release];
            return nil;
        }
        [dict setObject:[pairs objectAtIndex:1] forKey:[pairs objectAtIndex:0]];
    }
    return dict;
}

// Parse an ASN1 string representing time from an X509 PKIX certificate.
- (NSDate *) copyAndParseASN1Date:(ASN1_TIME *)time {
    struct tm tm;
    char buf[20];

    // RFC 5280, 4.1.2.5.1 UTCTime
    // For the purposes of this profile, UTCTime values MUST be expressed in
    // Greenwich Mean Time (Zulu) and MUST include seconds (i.e., times are
    // YYMMDDHHMMSSZ), even where the number of seconds is zero.  Conforming
    // systems MUST interpret the year field (YY) as follows:
    //
    // Where YY is greater than or equal to 50, the year SHALL be
    // interpreted as 19YY; and
    //
    // Where YY is less than 50, the year SHALL be interpreted as 20YY.
    if (time->type == V_ASN1_UTCTIME && time->length == 13 && time->data[12] == 'Z') {
        memcpy(buf+2, time->data, time->length-1);        
        if (time->data[0] >= '5') {
            buf[0] = '1';
            buf[1] = '9';
        } else {
            buf[0] = '2';
            buf[1] = '0';
        }
    // RFC 5280, 4.1.2.5.2. GeneralizedTime
    //
    // GeneralizedTime values MUST be expressed in Greenwich Mean Time (Zulu)
    // and MUST include seconds (i.e., times are YYYYMMDDHHMMSSZ), even where
    // the number of seconds is zero.  GeneralizedTime values MUST NOT include
    // fractional seconds.
    } else if (time->type == V_ASN1_GENERALIZEDTIME && time->length == 15 && time->data[14] == 'Z') {
        memcpy(buf, time->data, time->length-1);
    } else {
        NSLog(@"MKCertificate: Invalid ASN.1 date for PKIX purposes encountered.");
        return nil;
    }

    buf[14] = '+';
    buf[15] = '0';
    buf[16] = '0';
    buf[17] = '0';
    buf[18] = '0';
    buf[19] = 0;
    if (strptime_l(buf, "%Y%m%d%H%M%S%z", &tm, NULL) == NULL) {
        NSLog(@"MKCertificate: Unable to parse ASN.1 date.");
        return nil;
    }
        
    return [[NSDate alloc] initWithTimeIntervalSince1970:mktime(&tm)];
}

- (void) extractCertInfo {
    X509 *x509 = NULL;
    const unsigned char *p = NULL;

    p = [_derCert bytes];
    x509 = d2i_X509(NULL, &p, [_derCert length]);

    if (x509) {
        // Extract subject information
        {
            BIO *mem = BIO_new(BIO_s_mem());
            X509_NAME *subject = X509_get_subject_name(x509);
            if (X509_NAME_print_ex(mem, subject, 0, XN_FLAG_ONELINE & ~ASN1_STRFLGS_ESC_MSB) > 0) {
                BUF_MEM *buf = NULL;
                BIO_get_mem_ptr(mem, &buf);
                NSData *data = [[NSData alloc] initWithBytes:buf->data length:buf->length];
                _subjectDict = [self copyDictForOneLineUTF8Repr:data];
                [data release];
            }
            BIO_free(mem);
        }

        // Extract issuer information
        {
            BIO *mem = BIO_new(BIO_s_mem());
            X509_NAME *issuer = X509_get_issuer_name(x509);
            if (X509_NAME_print_ex(mem, issuer, 0, XN_FLAG_ONELINE & ~ASN1_STRFLGS_ESC_MSB) > 0) {
                BUF_MEM *buf = NULL;
                BIO_get_mem_ptr(mem, &buf);
                NSData *data = [[NSData alloc] initWithBytesNoCopy:buf->data length:buf->length freeWhenDone:NO];
                _issuerDict = [self copyDictForOneLineUTF8Repr:data];
                [data release];
            }
            BIO_free(mem);
        }

        // Extract notBefore and notAfter
        ASN1_TIME *notBefore = X509_get_notBefore(x509);
        if (notBefore) {
            _notBeforeDate = [self copyAndParseASN1Date:notBefore];
        }
        ASN1_TIME *notAfter = X509_get_notAfter(x509);
        if (notAfter) {
            _notAfterDate = [self copyAndParseASN1Date:notAfter];
        }

        // Extract Subject Alt Names
        STACK_OF(GENERAL_NAME) *subjAltNames = X509_get_ext_d2i(x509, NID_subject_alt_name, NULL, NULL);
        int num = sk_GENERAL_NAME_num(subjAltNames);
        for (int i = 0; i < num; i++) {
            GENERAL_NAME *name = sk_GENERAL_NAME_value(subjAltNames, i);
            unsigned char *strPtr = NULL;

            switch (name->type) {
                case GEN_DNS: {
                    if (!_dnsEntries)
                        _dnsEntries = [[NSMutableArray alloc] init];
                    ASN1_STRING_to_UTF8(&strPtr, name->d.ia5);
                    NSString *dns = [[NSString alloc] initWithUTF8String:(char *)strPtr];
                    [_dnsEntries addObject:dns];
                    [dns release];
                    break;
                }
                case GEN_EMAIL: {
                    if (!_emailAddresses)
                        _emailAddresses = [[NSMutableArray alloc] init];
                    ASN1_STRING_to_UTF8(&strPtr, name->d.ia5);
                    NSString *email = [[NSString alloc] initWithUTF8String:(char *)strPtr];
                    [_emailAddresses addObject:email];
                    [email release];
                    break;
                }
                // fixme(mkrautz): There's an URI alt name as well.
                default:
                    break;
            }

            OPENSSL_free(strPtr);
        }

        sk_pop_free((_STACK *) subjAltNames, (void (*)(void *)) sk_free);
        X509_free(x509);
    }
}

// Return a SHA1 digest of the contents of the certificate
- (NSData *) digest {
    if (_derCert == nil)
        return nil;

    unsigned char buf[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([_derCert bytes], [_derCert length], buf);
    return [NSData dataWithBytes:buf length:CC_SHA1_DIGEST_LENGTH];
}

// Return a hex-encoded SHA1 digest of the contents of the certificate
- (NSString *) hexDigest {
    if (_derCert == nil)
        return nil;

    const char *tbl = "0123456789abcdef";
    char hexstr[CC_SHA1_DIGEST_LENGTH*2 + 1];
    unsigned char *buf = (unsigned char *)[[self digest] bytes];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        hexstr[2*i+0] = tbl[(buf[i] >> 4) & 0x0f];
        hexstr[2*i+1] = tbl[buf[i] & 0x0f];
    }
    hexstr[CC_SHA1_DIGEST_LENGTH*2] = 0;
    return [NSString stringWithCString:hexstr encoding:NSASCIIStringEncoding];
}

// Get the common name of a MKCertificate.  If no common name is available,
// nil is returned.
- (NSString *) commonName {
    return [_subjectDict objectForKey:MKCertificateItemCommonName];
}

// Get the email of the subject of the MKCertificate.  If no email is available,
// nil is returned.
- (NSString *) emailAddress {
    if (_emailAddresses && [_emailAddresses count] > 0) {
        return [_emailAddresses objectAtIndex:0];
    }
    return nil;
}

// Get the issuer name of the MKCertificate.  If no issuer is present, nil is returned.
- (NSString *) issuerName {
    return [self issuerItem:MKCertificateItemCommonName];
}

// Returns the expiry date of the certificate.
- (NSDate *) notAfter {
    return _notAfterDate;
}

// Returns the notBefore date of the certificate.
- (NSDate *) notBefore {
    return _notBeforeDate;
}

// Look up an issuer item.
- (NSString *) issuerItem:(NSString *)item {
    return [_issuerDict objectForKey:item];
}

// Look up a subject item.
- (NSString *) subjectItem:(NSString *)item {
    return [_subjectDict objectForKey:item];
}

@end

@interface MKRSAKeyPair () {
    NSData                    *_publicKey;
    NSData                    *_privateKey;
}
- (void) genKeysWithSize:(NSUInteger)bits;
@end

@implementation MKRSAKeyPair

+ (MKRSAKeyPair *) generateKeyPairOfSize:(NSUInteger)bits withDelegate:(id<MKRSAKeyPairDelegate>)delegate {
    MKRSAKeyPair *kp = [[MKRSAKeyPair alloc] init];
    if (delegate == nil) {
        [kp genKeysWithSize:bits];
    } else {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [kp genKeysWithSize:bits];
            dispatch_async(dispatch_get_main_queue(), ^{
                [delegate rsaKeyPairDidFinishGenerating:kp]; 
            });
        });
    }
    return [kp autorelease];
}

- (void) dealloc {
    [_privateKey release];
    [_publicKey release];
    [super dealloc];
}

- (void) genKeysWithSize:(NSUInteger)bits {
    EVP_PKEY *pkey = EVP_PKEY_new();
    RSA *rsa = RSA_generate_key((int)bits, RSA_F4, NULL, NULL);
    EVP_PKEY_assign_RSA(pkey, rsa);
    
    NSMutableData *data = [[NSMutableData alloc] initWithLength:i2d_PrivateKey(pkey, NULL)];
    unsigned char *ptr = [data mutableBytes];
    i2d_PrivateKey(pkey, &ptr);
    _privateKey = data;
    
    data = [[NSMutableData alloc] initWithLength:i2d_PublicKey(pkey, NULL)];
    ptr = [data mutableBytes];
    i2d_PublicKey(pkey, &ptr);
    _publicKey = data;
}

- (NSData *) publicKey {
    return _publicKey;
}

- (NSData *) privateKey {
    return _privateKey;
}

@end