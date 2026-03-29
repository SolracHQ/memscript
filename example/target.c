#include <stdio.h>
#include <unistd.h>

int main() {
    int health = 100;
    printf("pid: %d  &health: %p\n", getpid(), (void*)&health);
    while (1) {
        printf("health: %d\n", health);
        sleep(5);
        if (health < 50) {
            health = 50;
        } else {
            health -= 1;
        }
    }
}