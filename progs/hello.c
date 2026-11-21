typedef unsigned long long u64;
typedef int i32;

typedef struct {
    void (*print)(const char *);
    void (*putc)(i32);
    void (*num)(u64);
    void (*nl)(void);
    i32 (*key)(void);
    i32 (*wait)(void);
    void (*yield)(void);
    void (*exits)(void);
    void (*sleep)(i32);
} api_t;

void _start(api_t *a)
{
    a->print("Hello from C!\n");
    a->nl();
    for (int i = 1; i <= 5; i++) {
        a->print("line ");
        a->num(i);
        a->putc('\n');
        a->sleep(20);
    }
    a->print("Press any key to close.\n");
    a->wait();
    a->exits();
}
