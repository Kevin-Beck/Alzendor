using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorServer.Actions
{
    public enum LogInStatus
    {
        LoggedOut,
        NewUser,
        RequestingSalt,
        RequestingConfirmation,
        LoggedIn
    }
}
