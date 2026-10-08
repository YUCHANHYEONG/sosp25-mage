#include <assert.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <inttypes.h>
#include <stdint.h>

// Define the array size and a global array
size_t array_size;
uint8_t *data;

pthread_mutex_t bench_start_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t  bench_start_cond  = PTHREAD_COND_INITIALIZER;
bool            bench_start       = false;

pthread_mutex_t finished_threads_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t  finished_threads_cond  = PTHREAD_COND_INITIALIZER;
int             finished_threads       = 0;

pthread_mutex_t bench_end_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t  bench_end_cond  = PTHREAD_COND_INITIALIZER;
bool            bench_end       = false;

// Give N seconds for thread activity to reach a steady state before
// benchmarking the system.
const int warmup_duration = 30;
const int benchmark_duration = 30;
const int heartbeat_secs = 1;

struct worker_args {
    int thread_id; // 1 indexed
    int num_workers;
    bool thread_leader;
    uint64_t benchmark_ops;

    uint32_t *page_order;
    size_t num_pages;
};

static struct timespec diff_timespec(struct timespec *t1, struct timespec *t0)
{
    assert(t1);
    assert(t0);
    struct timespec diff = {
        .tv_sec = t1->tv_sec - t0->tv_sec,
        .tv_nsec = t1->tv_nsec - t0->tv_nsec
    };

    if (diff.tv_nsec < 0) {
        diff.tv_nsec += 1000000000;
        diff.tv_sec--;
    }
    return diff;
}

static uint8_t frobnicate(size_t index, uint64_t iteration)
{
    return (index ^ 'f') + iteration;
}

static void workload_function(struct worker_args *args)
{
    int thread_id = args->thread_id;
    int num_threads = args->num_workers;

    /*
     * Each thread receives a fixed random permutation of its pages.
     * Randomization is prepared before the benchmark starts.
     */
    uint32_t *page_order = args->page_order;
    size_t num_pages = args->num_pages;

    struct timespec start_time, last_heartbeat_time;
    clock_gettime(CLOCK_MONOTONIC, &start_time);
    last_heartbeat_time = start_time;

    // Frobnicate the data.
    uint64_t iteration = 0;
    int iterations_since_check = 0;
    bool started_benchmarks = false;
    uint64_t acc = 0;

    /*
     * Application-level performance measurement.
     * Do not count every access.
     * Snapshot the current progress only at the beginning and end
     * of the 30-second measurement interval.
     */
    bool app_measurement_started = false;
    uint64_t app_start_ops = 0;
    uint64_t app_end_ops = 0;
    uint64_t ops_per_sweep =
        (uint64_t)num_pages * 4;

    while(true) { 
        iteration++;

        for (size_t p = 0; p < num_pages; p++) {
            size_t page_base = (size_t)page_order[p] * 4096;

            /*
             * Keep the same four accesses per 4 KiB page as
             * Sequential Read. Only the page visiting order changes.
             */
            for (size_t off = 0; off < 4096; off += 1024) {
                size_t i = page_base + off;

                acc += data[i] + frobnicate(i, iteration);

                iterations_since_check++;
                if (iterations_since_check >= 512) {
                    iterations_since_check = 0;
                    struct timespec current_time, thread_runtime;

                    clock_gettime(CLOCK_MONOTONIC, &current_time);
                    thread_runtime = diff_timespec(&current_time, &start_time);

                    uint64_t current_ops =
                        (iteration - 1) * ops_per_sweep +
                        (uint64_t)p * 4 +
                        (off / 1024) + 1;

                    /*
                     * Snapshot application progress at the beginning
                     * of the measurement interval.
                     */
                    if (!app_measurement_started &&
                            thread_runtime.tv_sec >= warmup_duration) {
                        app_start_ops = current_ops;
                        app_measurement_started = true;
                    }

                    if (diff_timespec(&current_time, &last_heartbeat_time).tv_sec >= heartbeat_secs) {
                        printf("Heartbeat: thread%d still alive\n", thread_id);
                        last_heartbeat_time = current_time;
                    }

                    if (thread_runtime.tv_sec >= warmup_duration + benchmark_duration) {
                        app_end_ops = current_ops;

                        if (args->thread_leader)
                             assert(started_benchmarks == true);
                        goto done;
                    }

                    if (args->thread_leader && !started_benchmarks
                            && thread_runtime.tv_sec >= warmup_duration) {
                        printf("BEGIN_BENCHMARK\n"); // signal to test framework
                        fflush(stdout);
                        started_benchmarks = true;
                    }
                }
            }
        }
    }

done:
    if (app_measurement_started && app_end_ops >= app_start_ops)
        args->benchmark_ops = app_end_ops - app_start_ops;
    else
        args->benchmark_ops = 0;

    printf("Thread %d stopping benchmarks, %d seconds have passed\n",
            thread_id, benchmark_duration);
    printf("acc=%" PRIu64 "\n", acc);
    if (args->thread_leader) {
        printf("END_BENCHMARK\n"); // signal to test framework
        fflush(stdout);
    }
}

// Function to be executed by each thread
static void *worker_thread_fn(void* arg) {
    struct worker_args *args = arg;
    int thread_id = args->thread_id;
    int num_threads = args->num_workers;

    printf("Thread %d waiting for permission to start\n", thread_id);
    pthread_mutex_lock(&bench_start_mutex);
    while (!bench_start)
         pthread_cond_wait(&bench_start_cond, &bench_start_mutex);
    pthread_mutex_unlock(&bench_start_mutex);
    printf("Thread %d starting\n", thread_id);

    workload_function(args);

    printf("Thread %d signalling completion\n", thread_id);
    pthread_mutex_lock(&finished_threads_mutex);
    finished_threads++;
    pthread_cond_signal(&finished_threads_cond);
    pthread_mutex_unlock(&finished_threads_mutex);

    printf("Thread %d waiting for permission to die\n", thread_id);
    pthread_mutex_lock(&bench_end_mutex);
    while (!bench_end)
         pthread_cond_wait(&bench_end_cond, &bench_end_mutex);
    pthread_mutex_unlock(&bench_end_mutex);

    pthread_exit(NULL);
}

int main(int argc, char* argv[]) {
    if (argc != 3) {
        printf("Usage: %s <number of threads> <array size>\n", argv[0]);
        return 1;
    }
    int num_workers = atoi(argv[1]);
    array_size = strtoul(argv[2], NULL, 10);

    printf("Allocating %ld bytes\n", array_size);
    data = malloc(array_size * sizeof(*data)); // sizeof(char) = 1
    if (data == NULL) {
        printf("Memory allocation failed.\n");
        return 1;
    }
    printf("Allocated %ld bytes\n", array_size);
    printf("ALLOC_DONE\n");

    // Initialize shared workload buffer
    for (size_t i = 0; i < array_size; i++)
         data[i] = frobnicate(i, 0);

    bench_start = false;
    finished_threads = 0;

    // Initialize thread arguments.
    struct worker_args worker_args[num_workers];

    /*
     * 4 GiB / 4 KiB = 1,048,576 pages.
     * Store one 32-bit page number per page (~4 MiB total).
     */
    size_t total_pages = array_size / 4096;
    uint32_t *page_order =
        malloc(total_pages * sizeof(*page_order));

    if (page_order == NULL) {
        printf("Page order allocation failed.\n");
        free(data);
        return 1;
    }

    for (int t = 0; t < num_workers; t++) {
        size_t first_page =
            total_pages * (size_t)t / num_workers;
        size_t last_page =
            total_pages * (size_t)(t + 1) / num_workers;
        size_t nr_pages = last_page - first_page;

        worker_args[t].thread_id = t + 1;
        worker_args[t].thread_leader = (t == 0);
        worker_args[t].num_workers = num_workers;
        worker_args[t].benchmark_ops = 0;
        worker_args[t].page_order = &page_order[first_page];
        worker_args[t].num_pages = nr_pages;

        for (size_t j = 0; j < nr_pages; j++)
            page_order[first_page + j] =
                (uint32_t)(first_page + j);

        /*
         * Deterministic Fisher-Yates shuffle.
         * This happens before benchmark execution, so RNG overhead
         * is not included in Application Ops/s.
         */
        uint64_t rng = 0x9e3779b97f4a7c15ULL ^ (uint64_t)(t + 1);

        for (size_t j = nr_pages; j > 1; j--) {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;

            size_t k = (size_t)(rng % j);

            uint32_t tmp = page_order[first_page + j - 1];
            page_order[first_page + j - 1] =
                page_order[first_page + k];
            page_order[first_page + k] = tmp;
        }
    }

    // Spawn worker threads, don't let them start the workload though.
    printf("Spawning %d threads.\n", num_workers);
    pthread_t threads[num_workers - 1];
    for (int i = 0; i < num_workers - 1; i++)
        pthread_create(&threads[i], NULL, worker_thread_fn, &worker_args[i+1]);

    // Signal 'benchmark begin' to worker threads!
    printf("Starting worker threads...\n");
    pthread_mutex_lock(&bench_start_mutex);
    bench_start = true;
    pthread_cond_broadcast(&bench_start_cond);
    pthread_mutex_unlock(&bench_start_mutex);

    // Perform work on main thread. This function signals the test framework when complete.
    workload_function(&worker_args[0]);

    sleep(2);

    // Wait for worker threads to finish
    printf("Waiting on worker threads to finish...\n");
    pthread_mutex_lock(&finished_threads_mutex);
    while (finished_threads < num_workers - 1)
         pthread_cond_wait(&finished_threads_cond, &finished_threads_mutex);
    pthread_mutex_unlock(&finished_threads_mutex);

    uint64_t total_ops = 0;
    for (int i = 0; i < num_workers; i++)
        total_ops += worker_args[i].benchmark_ops;

    printf("TOTAL_OPS %" PRIu64 "\n", total_ops);
    fflush(stdout);

    sleep(2);

    // Allow workers to die
    printf("Commanding workers to die...\n");
    pthread_mutex_lock(&bench_end_mutex);
    bench_end = true;
    pthread_cond_broadcast(&bench_end_cond);
    pthread_mutex_unlock(&bench_end_mutex);

    // Wait for threads to finish
    printf("Joining with workers...\n");
    for (int i = 0; i < num_workers - 1; i++) {
        pthread_join(threads[i], NULL);
    }
    printf("Threads done.\n");

    // Write to dev null. Do this so the array math isn't optimized out.
    FILE *null_file = fopen("/dev/null", "w");
    size_t elements_written = fwrite(data, 1, array_size, null_file);
    if (elements_written != array_size) {
        perror("Failed to write to /dev/null");
        fclose(null_file);
        return 1;
    }
    fclose(null_file);

    free(page_order);
    free(data);
    return 0;
}
