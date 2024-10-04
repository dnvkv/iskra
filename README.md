# Iskra

Iskra is a Ruby library for type safe structured concurrent programming using light-weight threads aka coroutines.

Corotine is a light-weight thread that exists only in user-space. Coroutines are backed up by Ruby OS threads using M:N scheduler,
so it doesn't corresponds as 1:1. Because of it, an app can spawn thousands of coroutines using just a handful of threads allowing
concurrent execution of thousands workers, which would not be possible with OS threads.

## Documentation

The main concurrent primitive of `Iskra` is a coroutine represented by abstract `Task[A]`. This type represents a coroutine which yields result of a parameterized type `A`. In order to create a task `Iskra::Task::Mixin` should be used.

The module `Iskra::Task::Mixin` contains dsl for launching code concurrently and managing of concurrent execution.

```ruby
include Iskra::Task::Mixin
```

Coroutine can be created using `#concurrent` method, which receives a block of code. Coroutines can only ran within `run_blocking` blocks. The method
receives a block, which returns a coroutine and executes it.

Make sure that all concurrent executed is executed within a `concurrent` scope and ran via `run_blocking`.

```ruby
run_blocking do
  concurrent { puts "In concurrent" }
end
# > In concurrent
```

`run_blocking` forms a concurrent scope. This way, no coroutine can escape scope of `run_blocking`. This means, that `#run_blocking` will await until all coroutines spawned within top-level coroutine are executed. We will talk more about this later.

### Iskra concurrency

Coroutine is a lighweight thread - a code is running concurrently to other code (another coroutines). Concurrent execution
of coroutines is enabled by cooperative (non-preemptive) multitasking. This means that each coroutine itself yields control before suspending.
This way at any given moment of time only 1 coroutine is physically executed, but since coroutine can yield control mid-execution, multiple coroutines
are running concurrently, and none time is wasted on blocking since coroutine can yield execution before IO operation.

Yielding of control happens in *suspension points* (usually any operation using coroutines DSL is a suspension point, later it is marked explicitly). For example, method `#concurrent` contains a suspension point.
In a suspension point a coroutine yields control to Iskra runtime which determines whether the coroutines should continue execution, or the new
coroutine should be taken into work. In latter case, current coroutines is suspended, and new coroutine is being executed.

```ruby
run_blocking do
  concurrent do
    coroutine1 = concurrent do
      puts "In coroutine 1. Step 1"
      # Some method with suspension that causes
      # Iskra runtime to shift execution.
      await_something
      puts "In coroutine 1. Step 2"
    end

    coroutine2 = concurrent do
      puts "In coroutine 2"
    end
  end
end
# Two of possible resuts:
#
# Result 1
# > In coroutine 1. Step 1
# > In coroutine 2
# > In coroutine 1. Step 2

# Result 2
# > In coroutine 2
# > In coroutine 1. Step 1
# > In coroutine 1. Step 2
```

Let's break down possible results.

Result 1: top level coroutines starts execution. During execution it calls `#concurent` which is stored into `coroutine1` variable. Iskra scheduler decides to continue execution of top-level coroutine, so another coroutine (coroutine2) is added to scheduler. After that, top level coroutine has no more code to execute, but since it forms a concurrent scope, it awaits until all nested coroutines are executed. Scheduler decides to start execution from `coroutine1`: it prints `In coroutine 1. Step 1`, but then coroutine is suspended via invokation of `#await_something`. Since `coroutine1` is suspended, 
scheduler decides to run `coroutine2`, and prints `In coroutine 2`. Then scheduler awaits until `coroutine1` is resumed and prints `In coroutine 1. Step 2`.

Result 2: top level coroutines starts execution. It schedules two coroutines. This time scheduler decides to start execution from `coroutine2`: it prints `In coroutine 2`, then coroutine finishes it's execution. Then scheduler decides to run `coroutine1`, and prints `In coroutine 1. Step 1`, and `In coroutine 1. Step 2` then finishes execution

Please not that execution is not shifted to other coroutine each time a coroutine hits a suspension point. Suspension point just allows Iskra runtime
to evaluate whether the current coroutine shoud be kept running, or execution should be shifted.

### Coroutines suspension

When a coroutine is semantically blocked or suspended, it is marked as blocked by Iskra runtime, thus allowing to run other coroutines while the blocked coroutine is awaiting on the computation. The underlying OS thread isn't blocked by semantic blocking.

#### Awaiting

Method `Iskra::Coroutine#await!` retreives result of coroutine. Since coroutines are running concurrently, calling `#await!` may suspend the caller coroutine.

```ruby 
run_blocking do
  concurrent do
    coroutine1 = concurrent do
      "Success"
    end
    puts coroutine1.await!
  end
end
# > Success
```

#### #delay

Method `#delay` suspendes current coroutine for a time provided. Receives float time in seconds.
This method is conceptual equivalent of `Kernel#sleep`, but for coroutines.

```ruby
run_blocking do
  concurrent do
    coroutine1 = concurrent do
      # Suspends current coroutine and signals scheduler to shift execution
      # to another coroutine. Current coroutine will be resumed by scheduler
      # after 100 milliseconds
      delay(0.1)
      puts "Coroutine 1. Step 1"
      puts "Coroutine 1. Step 2"
    end

    coroutine1 = concurrent do
      puts "Coroutine 2. Step 1"
      # Suspends current coroutine and signals scheduler to shift execution
      # to another coroutine. Current coroutine will be resumed by scheduler
      # after 200 milliseconds
      delay(0.2)
      puts "Coroutine 2. Step 2"
    end
  end
end
# > Coroutine 2. Step 1
# > Coroutine 1. Step 1
# > Coroutine 1. Step 2
# > Coroutine 2. Step 2
```

#### #cede

The easiest way to insert a suspension point is method `#cede`. This method does nothing, but trigger a coroutine to yield execution to runtime.

This method useful when there's a long running CPU-computation which may lead
to a coroutine hogging an execution, thus causing other coroutine to starve.

```ruby
data = fetch_some_data

run_blocking do
  concurrent do
    coroutine1 = concurrent do
      data.map do |datum|
        long_running_computation(datum).tap do
          # Signals scheduler that execution can be shifted to another coroutine.
          # It doesn't gurantee that execution will be transfered, and that this corutines will paused though.
          cede
        end
      end
    end

    # without ceding coroutine1 would be executing until all
    # memeber of data variable is processed, and coroutine2 would be idle,
    # thus causing high latency
    coroutine2 = concurrent do
      loop do
        request = receive_request
        response = process(request)
        send_response(response)
      end
    end
  end
end
```

### #async

Method `#async` creates a coroutine that is executed in thread pool. This allows to run code non blockingly. `#async` is suspension point.

Since `#async` returns a coroutine (or to be more specifically an instance of `Iskra::Task::Async` a subtype of `Iskra::Task`), later called *async*, in order ot retrieve a result method `Iskra::Task#await!` must be called on the async. Since this computation is asynchronous, it may not return result immediately, the coroutine will be suspended.

It is recommended to wrap any IO operation into `#async`.

```ruby
run_blocking do
  concurrent do
    async { puts "Enter url" }.await!
    url = async { gets }.await!

    # Note that there's no call to #await!
    # so this line doesn't suspends current coroutine
    fetching_url_content = async { open(url) }

    async { puts "Enter file name" }.await!
    file_name = async { gets }.await!

    url_content = fetching_url_content.await!
    writing_to_file = async do
      File.open(file_name, 'w') { |file| file.write(url_content) }
    end
    writing_to_file.await!
  end
end
```

### #blocking

Sometimes result `async` required just after the execution, so there's no need to store the coroutine. In this case `#blocking` can be used. `blocking! { ... }` is equivalent to `async { ... }.await!`.

```ruby
run_blocking do
  concurrent do
    blocking! { puts "Enter url" }
    url = blocking! { gets }
    fetching_url_content = async { open(url) }

    blocking! { puts "Enter file name" }
    file_name = blocking! { gets }
    
    url_content = fetching_url_content.await!
    writing_to_file = blocking! do
      File.open(file_name, 'w') { |file| file.write(url_content) }
    end
  end
end
```

### Concurrent scope

Concurrent scope is a scope that suspends current coroutine
until all coroutines in the scope finish. 

```ruby
run_blocking do
  concurrent do
    scope = concurrent_scope do
      delay(0.1)
      blocking! { puts("After 0.1 delay") }

      delay(0.2)
      blocking! { puts("After 0.2 delay") }
    end
    blocking! { puts("In outer") }
  end
end
# > After 0.1 delay
# > After 0.2 delay
# > In outer
```
Note that without concurrent scope scheduler would execute outer coroutine first, so "In outer" will be printed first, since `scope` coroutine will be suspended by `delay` thus making scheduler to prioritize execution of top level coroutine.