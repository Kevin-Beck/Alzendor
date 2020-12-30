using System;
using System.Collections.Generic;
using System.Text;

namespace Server.Actions
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
